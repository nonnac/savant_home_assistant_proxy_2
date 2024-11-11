WS_TOKEN = ENV['SUPERVISOR_TOKEN']
WS_URL = "ws://supervisor/core/api/websocket"
TCP_PORT = 8080
require 'socket'
require 'json'
require 'fcntl'
require 'logger'
require 'websocket/driver'
require 'fileutils'

class AppLogger
  def self.setup(file_name, log_path: "#{Dir.home}/logfiles", log_level: Logger::WARN)
    script_name = File.basename(file_name, '.*')
    log_path = "#{log_path}/#{script_name}/"
    FileUtils.mkdir_p(log_path)

    log_filename = "#{log_path}#{script_name}_#{Time.now.strftime('%Y-%m-%d')}.log"

    logger = Logger.new(STDOUT, 10, 1024 * 1024 * 10)
    logger.level = log_level

    # Extend logger to include a method for logging with caller details
    def logger.log_error(message)
      error_location = caller(1..1).first # gets the immediate caller's details
      error_message = "[#{error_location}] #{message}"
      error(error_message)
    end

    logger
  end
end

LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
# LOG = Logger.new(STDOUT)
LOG.formatter = proc do |severity, datetime, _progname, msg|
  "#{severity[0]}-#{datetime.strftime("%d %H:%M:%S")}: #{msg}\n"
end
LOG.level = Logger::DEBUG



module TimeoutInterface
  def add_timeout(callback_proc, duration)
    SelectController.instance.add_timeout(callback_proc, duration)
  end

  def timeout?(callback_proc)
    SelectController.instance.timeout?(callback_proc)
  end

  def remove_timeout(callback_proc)
    SelectController.instance.remove_timeout(callback_proc)
  end
end

module SocketInterface
  def read_proc(sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.readable?(sock)
  end

  def write_proc(sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.writable?(sock)
  end

  def add_readable(readable_proc, sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.add_sock(readable_proc, sock)
  end

  def remove_readable(sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.remove_sock(sock)
  end

  def add_writable(writable_proc, sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.add_sock(writable_proc, sock, for_write: true)
  end

  def remove_writable(sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.remove_sock(sock, for_write: true)
  end
end

module HassMessageParsingMethods
  def new_data(js_data)
    return {} unless js_data['data']

    js_data['data']['new_state'] || js_data['data']
  end

  def parse_event(js_data)
    return entities_changed(js_data['c']) if js_data.keys == ['c']
    return entities_changed(js_data['a']) if js_data.keys == ['a']

    case js_data['event_type']
    when 'state_changed' then parse_state(new_data(js_data))
    when 'call_service' then parse_service(new_data(js_data))
    else
      [:unknown, js_data['event_type']]
    end
  end

  def entities_changed(entities)
    entities.each do |entity, state|
      state = state['+'] if state.key?('+')
      LOG.debug([:changed, entity, state])
      attributes = state['a']
      value = state['s']
      update?("#{entity}_state", 'state', value) if value
      update_with_hash(entity, attributes) if attributes
    end
  end

  def parse_service(data)
    return [] unless data['service_data'] && data['service_data']['entity_id']

    [data['service_data']['entity_id']].flatten.compact.map do |entity|
      "type:call_service,entity:#{entity},service:#{data['service']},domain:#{data['domain']}"
    end
  end

  def included_with_filter?(primary_key)
    return true if @filter.empty? || @filter == ['all']

    @filter.include?(primary_key)
  end

  def parse_state(message)
    eid = message['entity_id']

    update?("#{eid}_state", 'state', message['state']) if eid

    atr = message['attributes']
    case atr
    when Hash then update_with_hash(eid, atr)
    when Array then update_with_array(eid, atr)
    end
  end

  def update?(key, primary_key, value)
    return unless value && included_with_filter?(primary_key)

    value = 3 if primary_key == 'brightness' && [1, 2].include?(value)

    to_savant("#{key}===#{value}")
  end

  def update_hashed_array(parent_key, msg_array)
    msg_array.each_with_index do |e, i|
      key = "#{parent_key}_#{i}"
      case e
      when Hash then update_with_hash(key, e)
      when Array then update_with_array(key, e)
      else
        update?(key, i, e)
      end
    end
  end

  def update_with_array(parent_key, msg_array)
    return update_hashed_array(parent_key, msg_array) if msg_array.first.is_a?(Hash)

    update?(parent_key, parent_key, msg_array.join(','))
  end

  def update_with_hash(parent_key, msg_hash)
    arr = msg_hash.map do |k, v|
      update?("#{parent_key}_#{k}", k, v) if included_with_filter?(k)
      "#{k}:#{v}"
    end
    return unless included_with_filter?('attributes')

    update?("#{parent_key}_attributes", parent_key, arr.join(','))
  end

  def parse_result(js_data)
    LOG.debug([:jsdata, js_data])
    res = js_data['result']
    return unless res

    LOG.debug([:parsing, res.length])
    return parse_state(res) unless res.is_a?(Array)

    res.each do |e|
      LOG.debug([:parsing, e.length, e.keys])
      parse_state(e)
    end
  end
end

module HassRequests
  def fan_on(entity_id, speed)
    send_data(
      type: :call_service, domain: :fan, service: :turn_on,
      service_data: { speed: speed },
      target: { entity_id: entity_id }
    )
  end

  def fan_off(entity_id, _speed)
    send_data(
      type: :call_service, domain: :fan, service: :turn_off,
      target: { entity_id: entity_id }
    )
  end

  def fan_set(entity_id, speed)
    speed.to_i.zero? ? fan_off(entity_id) : fan_on(entity_id, speed)
  end

  def switch_on(entity_id)
    send_data(
      type: :call_service, domain: :light, service: :turn_on,
      target: { entity_id: entity_id }
    )
  end

  def switch_off(entity_id)
    send_data(
      type: :call_service, domain: :light, service: :turn_off,
      target: { entity_id: entity_id }
    )
  end

  def dimmer_on(entity_id, level)
    send_data(
      type: :call_service, domain: :light, service: :turn_on,
      service_data: { brightness_pct: level },
      target: { entity_id: entity_id }
    )
  end

  def dimmer_off(entity_id)
    send_data(
      type: :call_service, domain: :light, service: :turn_off,
      target: { entity_id: entity_id }
    )
  end

  def dimmer_set(entity_id, level)
    level.to_i.zero? ? dimmer_off(entity_id) : dimmer_on(entity_id, level)
  end

  def shade_set(entity_id, level)
    send_data(
      type: :call_service, domain: :cover, service: :set_cover_position,
      service_data: { position: level },
      target: { entity_id: entity_id }
    )
  end

  def lock_lock(entity_id)
    send_data(
      type: :call_service, domain: :lock, service: :lock,
      target: { entity_id: entity_id }
    )
  end

  def unlock_lock(entity_id)
    send_data(
      type: :call_service, domain: :lock, service: :unlock,
      target: { entity_id: entity_id }
    )
  end

  def open_garage_door(entity_id)
    send_data(
      type: :call_service, domain: :cover, service: :open_cover,
      target: { entity_id: entity_id }
    )
  end

  def button_press(entity_id)
    send_data(
      type: :call_service, domain: :button, service: :press,
      target: { entity_id: entity_id }
    )
  end

  def close_garage_door(entity_id)
    send_data(
      type: :call_service, domain: :cover, service: :close_cover,
      target: { entity_id: entity_id }
    )
  end

  def toggle_garage_door(entity_id)
    send_data(
      type: :call_service, domain: :cover, service: :toggle,
      target: { entity_id: entity_id }
    )
  end

  def socket_on(entity_id)
    send_data(
      type: :call_service, domain: :switch, service: :turn_on,
      target: { entity_id: entity_id }
    )
  end

  def socket_off(entity_id)
    send_data(
      type: :call_service, domain: :switch, service: :turn_off,
      target: { entity_id: entity_id }
    )
  end

  def climate_set_hvac_mode(entity_id, mode)
    send_data(
      type: :call_service, domain: :climate, service: :set_hvac_mode,
      service_data: { hvac_mode: mode },
      target: { entity_id: entity_id }
    )
  end
  
  def climate_set_single(entity_id, level)
    send_data(
      type: :call_service, domain: :climate, service: :set_temperature,
      service_data: { temperature: level },
      target: { entity_id: entity_id }
    )
  end

  def climate_set_temperature_range(entity_id, temp_low, temp_high)
    send_data(
      type: :call_service, domain: :climate, service: :set_temperature,
      service_data: { target_temp_low: temp_low, target_temp_high: temp_high },
      target: { entity_id: entity_id }
    )
  end

  def remote_on(entity_id)
    send_data(
      type: :call_service, domain: :remote, service: :turn_on,
      target: { entity_id: entity_id }
    )
  end

  def remote_off(entity_id)
    send_data(
      type: :call_service, domain: :remote, service: :turn_off,
      target: { entity_id: entity_id }
    )
  end

  def remote_send_command(entity_id, command)
    send_data(
      type: :call_service, domain: :remote, service: :send_command,
      service_data: { command: command },
      target: { entity_id: entity_id }
    )
  end

  def media_player_on(entity_id)
    send_data(
      type: :call_service, domain: :media_player, service: :turn_on,
      target: { entity_id: entity_id }
    )
  end

  def media_player_off(entity_id)
    send_data(
      type: :call_service, domain: :media_player, service: :turn_off,
      target: { entity_id: entity_id }
    )
  end

  def mediaplayer_send_command(entity_id, command)
    send_data(
      type: :call_service, domain: :remote, service: :send_command,
      service_data: { command: command },
      target: { entity_id: entity_id }
    )
  end
end


class Hass
  include TimeoutInterface
  include HassMessageParsingMethods
  include HassRequests

  POSTFIX = "\n"

  def initialize(hass_address, token, client, filter = ['all'])
    LOG.debug([:connecting_to, hass_address])
    @address = hass_address
    @token = token
    @filter = filter
    @client = client
    @client.wait_io = true
    @id = 0
    connect_websocket
    @client.on(:data, method(:from_savant))
  end

  def subscribe_entities(*entity_id)
    return if entity_id.empty?

    send_json(
      type: 'subscribe_entities',
      entity_ids: entity_id.flatten
    )
  end

  def send_data(**data)
    LOG.debug(data)
    send_json(data)
  end

  def from_savant(reqs, _)
    reqs.split("\n").each do |req|
      # LOG.debug([:skipping_from_savant, req])
      cmd, *params = req.split(',')
      if cmd == 'subscribe_events' then send_json(type: 'subscribe_events')
      elsif cmd == 'subscribe_entity' then subscribe_entities(params)
      elsif cmd == 'state_filter' then @filter = params
      elsif hass_request?(cmd) then send(cmd, *params)
      else LOG.error([:unknown_cmd, cmd, req])
      end
    end
  end

  def close_connection
    LOG.debug([:closing_hass_connection])
    stop_ping_timer
    @hass_ws.close if @hass_ws
  end

  private

  def connect_websocket
    ws_url = @address
    @hass_ws = NonBlockSocket::TCP::WebSocketClient.new(ws_url)
  
    @hass_ws.on :open do |_event|
      LOG.debug([:ws_connected])
      start_ping_timer
    end
  
    @hass_ws.on :message do |event|
      handle_message(event)
    end
  
    @hass_ws.on :close do |event|
      LOG.debug([:ws_disconnected, event.code, event.reason])
      stop_ping_timer
      reconnect_websocket
    end
  
    @hass_ws.on :error do |event|
      LOG.error([:ws_error, event])
      @hass_ws = nil
      reconnect_websocket
    end
  end

  def start_ping_timer
    send_json(type: 'ping')
    add_timeout(method(:start_ping_timer), 30)
  end
  
  def stop_ping_timer
    remove_timeout(method(:start_ping_timer))
  end

  def reconnect_websocket
    return if @reconnecting
    @reconnecting = true
    LOG.info([:reconnecting_websocket])
    add_timeout(
      proc {
        @reconnecting = false
        connect_websocket
      },
      5
    )
  end

  def hass_request?(cmd)
    cmd = cmd.to_sym
    LOG.debug([cmd, HassRequests.instance_methods(false)])
    HassRequests.instance_methods(false).include?(cmd.to_sym)
  end

  def handle_message(data)
    return unless (message = JSON.parse(data))
    return LOG.error([:request_failed, message]) if message['success'] == false

    LOG.debug([:handling, message])
    handle_hash(message)
  end

  def handle_hash(message)
    case message['type']
    when 'auth_required' then send_auth
    when 'event' then parse_event(message['event'])
    when 'result' then parse_result(message)
    when 'pong' then LOG.debug([:pong_received])
    when 'auth_ok' then @client.wait_io = false
    end
  end

  def send_auth
    auth_message = { type: 'auth', access_token: @token }.to_json
    LOG.debug([:sending_auth])
    @hass_ws.send(auth_message)
  end

  def send_json(hash)
    @id += 1
    hash['id'] = @id
    hash = hash.to_json
    LOG.debug([:send, hash])
    @hass_ws.send(hash)
  end

  def to_savant(*message)
    return unless message

    @client.write(map_message(message).join)
  end

  def map_message(message)
    Array(message).map do |m|
      next unless m

      [m.to_s.gsub(POSTFIX, ''), POSTFIX]
    end
  end
end

class EventBus
  @instance = nil
  class << self
    def instance
      @instance ||= new
    end

    def subscribe(...)
      instance.subscribe(...)
    end

    def unsubscribe(...)
      instance.unsubscribe(...)
    end

    def publish(...)
      instance.publish(...)
    end
  end

  private_class_method :new

  def initialize
    @subscribers = {} # Hash.new { |h, k| h[k] = [] }
  end

  def subscribe(event_path, event_name, prc)
    key = build_key(event_path, event_name)
    LOG.debug([:new_subscription, key, prc])
    @subscribers[key] ||= []
    @subscribers[key] << prc
  end

  def unsubscribe(event_path, event_name, prc)
    key = build_key(event_path, event_name)
    LOG.debug([:unsubscribing, key, prc, @subscribers[key].length])
    @subscribers[key].delete(prc)
  end

  def publish(event_path, event_name, *args)
    LOG.debug([:event_published, event_path, event_name, args])
    key = build_key(event_path, event_name)
    notify_subscribers(key, args)
  end

  private

  def build_key(path, name)
    "#{path}:#{name}"
  end

  def notify_subscribers(key, args)
    LOG.debug([:notifying, key, :count, @subscribers[key]&.length])
    @subscribers[key]&.each { |handler| handler.call(args) }
    # Notify wildcard subscribers
    wildcard_key = "#{key.split(':').first}:*"
    @subscribers[wildcard_key]&.each { |handler| handler.call(args) unless key == wildcard_key }
  end
end

module SelectHandlerMethods
  def handle_err(err_socks)
    return unless err_socks.is_a?(Array)

    LOG.debug([:error, err_socks])
    handle_readable(err_socks)
  end

  def handle_writable(writable)
    return unless writable.is_a?(Array)

    writable.each { |sock| @writable[sock]&.call }
  end

  def handle_readable(readable)
    return unless readable.is_a?(Array)

    readable.each { |sock| @readable[sock]&.call }
  end

  def handle_timeouts
    current_time = Time.now
    touts = @timeouts.keys
    touts.each do |callback_proc|
      # LOG.debug callback_proc
      timeout = @timeouts[callback_proc]
      next unless current_time >= timeout

      @timeouts.delete(callback_proc)
      callback_proc.call
    end
  end
end

class SelectController
  MAX_SOCKS = 50
  @instance = nil
  class << self
    def instance
      @instance ||= new
    end

    def run
      instance.run
    end
  end
  private_class_method :new

  include SelectHandlerMethods

  def initialize
    reset
  end

  def readable?(sock)
    @readable[sock]
  end

  def writable?(sock)
    @writable[sock]
  end

  def add_sock(call_proc, sock, for_write: false)
    raise "IO type required for socket argument: #{sock.class}" unless sock.is_a?(IO)
    raise "invalid proc detected: #{call_proc.class}" unless call_proc.respond_to?(:call)

    for_write ? @writable[sock] = call_proc : @readable[sock] = call_proc
  end

  def remove_sock(sock, for_write: false)
    # LOG.debug(["removing_#{for_write ? 'write' : 'read'}_socket", sock, sock.object_id])
    for_write ? @writable.delete(sock) : @readable.delete(sock)
  end

  def remove_readables(socks)
    socks.each { |sock| remove_sock(sock) }
    @writable.each_key { |sock| remove_sock(sock, for_write: true) }
  end

  def stop
    remove_readables(@readable.keys)
  end

  def timeout?(callback_proc)
    @timeouts[callback_proc]
  end

  def add_timeout(callback_proc, seconds)
    # LOG.debug callback_proc
    raise 'positive value required for seconds parameter' unless seconds.positive?
    raise "invalid proc detected: #{callback_proc.class}" unless callback_proc.respond_to?(:call)

    @timeouts[callback_proc] = Time.now + seconds
  end

  def remove_timeout(callback_proc)
    @timeouts.delete(callback_proc)
  end

  def reset
    @readable = {}
    @writable = {}
    @timeouts = {}
    at_exit do
      stop
    end
  end

  def run
    loop { select_socks }
    # $stdout.puts([Time.now, 'ok', Process.pid])
  rescue StandardError => e
    LOG.error([:uncaught_exception_while_select, e])
    LOG.error("Backtrace:\n\t#{e.backtrace.join("\n\t")}")
    exit
  end

  private

  def readables
    @readable.delete_if { |socket, _| socket.closed? }
    @readable.keys
  end

  def writeables
    @writable.delete_if { |socket, _| socket.closed? }
    @writable.keys
  end


  def run_select
    rd = readables
    # LOG.debug([:selecting, rd])
    raise "socks limit #{MAX_SOCKS} exceeded in select loop." if rd.length > MAX_SOCKS

    select(rd, writeables, rd, calculate_next_timeout)
  rescue IOError => e
    LOG.error([:io_error_in_select, e])
  end

  def select_socks
    # LOG.debug @readable
    readable, writable, err = run_select
    # LOG.debug readable
    return handle_err(err) if err && !err.empty?

    handle_timeouts
    handle_writable(writable) if writable
    handle_readable(readable) if readable
  end

  def calculate_next_timeout
    tnow = Time.now
    return nil if @timeouts.empty?

    [@timeouts.values.min, tnow].max - tnow
  end
end

# SelectController.instance.setup

module NonBlockSocket; end
module NonBlockSocket::TCP; end
module NonBlockSocket::TCP::SocketExtensions; end

module NonBlockSocket::TCP::SocketExtensions::SocketIO
  CHUNK_LENGTH = 1024 * 16

  def write(data)
    return unless data

    @output_table ||= []
    @output_table << data
    return if @wait_io

    add_writable(method(:write_message), to_io)
    # LOG.debug([:added_to_write_queue, data])
  end

  private

  def read_chunk
    # LOG.debug(['reading'])
    dat = to_sock.read_nonblock(CHUNK_LENGTH)
    # LOG.debug(['read', dat])
    raise(EOFError, 'Nil return on readable') unless dat

    handle_data(dat)
  rescue EOFError, Errno::EPIPE, Errno::ECONNREFUSED, Errno::ECONNRESET => e
    LOG.debug([:read_chunk_error, :read, dat.to_s.length, e])
    on_disconnect(dat)
    on_error(e, e.backtrace)
  rescue IO::WaitReadable
    # IO not ready yet
  end

  def write_chunk
    # LOG.debug(['writing', @write_buffer])
    written = to_sock.write_nonblock(@write_buffer)
    # LOG.debug(['wrote', written])
    @write_buffer = @write_buffer[written..] || ''.dup
  rescue EOFError, Errno::EPIPE, Errno::ECONNREFUSED, Errno::ECONNRESET => e
    on_error(e, e.backtrace)
    on_disconnect
  rescue IO::WaitWritable
    # IO not ready yet
  end

  def write_message
    return next_write unless @write_buffer.empty?
    return if @output_table.empty?

    @write_buffer << @output_table.shift
    @current_output = @write_buffer
    write_chunk
    next_write
  end

  def next_write
    on_wrote(@current_output) if @write_buffer.empty?
    return unless @output_table.empty?

    on_empty
    remove_writable(to_io)
    close if @close_after_write
  end
end

module NonBlockSocket::TCP::SocketExtensions::Events
  def trigger_event(event_name, *args)
    # LOG.debug([:event, event_name, args, self])
    handler = @handlers[event_name]
    handler&.call(*args)
  end

  def on_empty
    trigger_event(:empty)
  end

  def on_error(error, backtrace)
    LOG.error([error, backtrace])
    @error_status = [error, backtrace]
    trigger_event(:error, @error_status, self)
  end

  def on_connect
    LOG.debug([:io_connected, self])
    @disconnected = false
    add_readable(method(:read_chunk), to_io)
    next_write
    trigger_event(:connect, self)
  end

  def on_disconnect(dat = nil)
    @disconnected = true
    on_data(dat) if dat
    remove_readable(to_io)
    remove_writable(to_io)
    close unless closed?
    trigger_event(:disconnect, self)
  end

  def on_data(data)
    trigger_event(:data, data, self)
  end

  def on_message(message)
    trigger_event(:message, message, self)
  end

  def on_wrote(message)
    return unless message

    @current_output&.clear
    trigger_event(:wrote, message, self)
  end
end

module NonBlockSocket::TCP::SocketExtensions
  include Events
  include SocketIO
  include SocketInterface
  include TimeoutInterface

  DEFAULT_BUFFER_LIMIT = 1024 * 16
  DEFAULT_BUFFER_TIMEOUT = 2

  attr_accessor :handlers, :read_buffer_timeout, :max_buffer_size

  def connected
    setup_buffers
    @handlers ||= {}
    on_connect
  end

  def add_handlers(handlers)
    handlers.each { |event, proc| on(event, proc) }
  end

  def on(event, proc = nil, &block)
    @handlers ||= {}
    @handlers[event] = proc || block
  end

  def to_io
    @socket
  end

  def to_sock
    @socket
  end

  def closed?
    to_sock ? to_sock.closed? : true
  end

  def close
    return if closed?

    to_sock.close
    on_disconnect unless @disconnected
  end

  private

  def setup_buffers
    @input_buffer ||= ''.dup
    @output_table ||= []
    @write_buffer ||= ''.dup
    @read_buffer_timeout ||= DEFAULT_BUFFER_TIMEOUT
    @max_buffer_size ||= DEFAULT_BUFFER_LIMIT
  end

  def handle_data(data)
    add_timeout(method(:handle_read_timeout), @read_buffer_timeout)
    LOG.debug([:handle_socket_data, object_id, data[0..10]])
    on_data(data)
    handle_message(data)
  end

  def handle_message(data)
    return unless (on_msg = @handlers[:message])
    return unless (pattern = on_msg.pattern)

    @input_buffer << data
    handle_buffer_overrun
    while (line = @input_buffer.slice!(pattern))
      on_message(line)
    end
  end

  class BufferOverrunError < StandardError; end

  def handle_buffer_overrun
    return unless @input_buffer.size > @max_buffer_size

    close
    raise BufferOverrunError, "Read buffer size exceeded for client: #{self}"
  end

  def handle_read_timeout
    return if @input_buffer.empty?

    LOG.info(["Read timeout reached for client: #{self}, clearing data from buffer: ", @input_buffer])
    @input_buffer = ''.dup
  end
end

class NonBlockSocket::TCP::Wrapper
  include NonBlockSocket::TCP::SocketExtensions

  attr_accessor :wait_io

  def initialize(socket)
    @socket = socket
    setup_buffers
  end
end

class NonBlockSocket::TCP::WebSocketClient
  include NonBlockSocket::TCP::SocketExtensions

  attr_reader :driver, :url

  def initialize(url, handlers: {})
    @url = url
    @uri = URI.parse(url)
    @host = @uri.host
    @port = @uri.port || 80
    @socket = nil
    @handlers = {}
    setup_buffers
    @driver = WebSocket::Driver.client(self)

    add_handlers(handlers)
    setup_websocket_handlers
    connect_nonblock
  end

  # Send a message via the WebSocket
  def send(data)
    @driver.text(data)
  end

  # Write data to the socket (called by the driver)
  def write(data)
    # LOG.debug([:sending_data, data])
    super(data)  # Ensure data is sent to the socket
  end

  def to_io
    @socket
  end

  private

  def connect_nonblock
    @socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
    @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    @socket.connect_nonblock(Socket.sockaddr_in(@port, @host), exception: false)
    readable?
  rescue => e
    on_error(e, e.backtrace)
    on_disconnect
  end

  def readable?
    to_io.read_nonblock(1)
    setup_io
  rescue IO::WaitWritable, IO::WaitReadable
    setup_io
  rescue Errno::ECONNREFUSED => e
    on_error(e, e.backtrace)
    on_disconnect
  end

  def setup_io
    remove_readable(to_io)
    @wait_io = false
    @driver.start  # Initiates the WebSocket handshake
    LOG.debug([:ws_driver_started])
    @handlers[:empty] = proc { add_readable(method(:read_chunk), to_io) }
    # connected
  end

  def setup_websocket_handlers
    @driver.on(:open)    { connected }
    @driver.on(:message) { |e| on_message(e.data) }
    @driver.on(:close)   { on_disconnect }
    @driver.on(:error)   { |e| on_error(e.message, e.backtrace) }
  end

  # Override handle_data to pass data to the driver
  def handle_data(data)
    # LOG.debug([:handle_ws_data, data])
    @driver.parse(data)
  end

  def connected
    super
    LOG.debug(['WebSocket connected', @host, @port])
  end
end

class NonBlockSocket::TCP::Server
  include SocketInterface
  include TimeoutInterface
  include Fcntl

  attr_reader :port

  CHUNK_LENGTH = 2048
  TCP_SERVER_FIRST_RETRY_SECONDS = 1
  TCP_SERVER_RETRY_LIMIT_SECONDS = 60
  TCP_SERVER_RETRY_MULTIPLIER = 2

  def initialize(**kwargs)
    @addr = kwargs[:host] || '0.0.0.0'
    @port = kwargs[:port] || 0
    @setup_proc = method(:setup_server)
    @handlers = kwargs[:handlers] || {}
    setup_server
  end

  def add_handlers(handlers)
    handlers.each { |event, proc| on(event, proc) }
  end

  def on(event, proc = nil, &block)
    @handlers[event] = proc || block
  end

  def setup_server
    @server ||= TCPServer.new(@addr, @port)
    @port = @server.addr[1]
    LOG.debug([self, @port])
    add_readable(method(:handle_accept), @server)
    LOG.info("Server setup complete, listening on port #{@port}")
  rescue Errno::EADDRINUSE
    port_in_use
  end

  def handle_accept
    LOG.info([:accepting_non_block_client, @port])
    client = @server.accept_nonblock
    setup_client(client)
  rescue IO::WaitReadable, IO::WaitWritable
    # If the socket isn't ready, ignore for now
  end

  def setup_client(client)
    client.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
    client = NonBlockSocket::TCP::Wrapper.new(client)
    @handlers.each { |k, v| client.on(k, v) }
    client.connected
  end

  def close
    @server.close
  end

  def available?
    !(@server.nil? || @server.closed?)
  end

  private

  def port_in_use
    LOG.error("TCP server could not start on Port #{@port} already in use")
    @server_setup_retry_seconds ||= TCP_SERVER_FIRST_RETRY_SECONDS
    exit if @server_setup_retry_seconds > TCP_SERVER_RETRY_LIMIT_SECONDS
    add_timeout(@setup_proc, @server_setup_retry_seconds * TCP_SERVER_RETRY_MULTIPLIER) unless timeout?(@setup_proc)
  end
end


def tcp_client_connected(client)
  hass = Hass.new(WS_URL, WS_TOKEN, client)
end

TCP_SERVER = NonBlockSocket::TCP::Server.new(
  port: TCP_PORT,
  handlers:{
    connect: (method(:tcp_client_connected))
  }
)

SelectController.run