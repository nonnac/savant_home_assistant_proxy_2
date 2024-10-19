WS_TOKEN = ENV['SUPERVISOR_TOKEN']
WS_URL = "ws://supervisor/core/api/websocket"
TCP_PORT = 8080
require 'socket'
require 'json'
require 'faye/websocket'
require 'eventmachine'
require 'logger'

LOG = Logger.new(STDOUT)
LOG.formatter = proc do |severity, datetime, _progname, msg|
  "#{severity[0]}-#{datetime.strftime("%d %H:%M:%S")}: #{msg}\n"
end
LOG.level = Logger::DEBUG

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
  include HassMessageParsingMethods
  include HassRequests

  POSTFIX = "\n"

  def initialize(hass_address, token, client, filter = ['all'])
    LOG.debug([:connecting_to, hass_address])
    @address = hass_address
    @token = token
    @filter = filter
    @client = client
    # @out_buf = []
    # @print_proc = proc { next_buf }
    @id = 0

    # Moved initialization code that requires EM into EM.run block
    EM.schedule do
      connect_websocket
    end

    # listen_to_savant
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

  def from_savant(req)
    cmd, *params = req.split(',')
    if cmd == 'subscribe_events' then send_json(type: 'subscribe_events')
    elsif cmd == 'subscribe_entity' then subscribe_entities(params)
    elsif cmd == 'state_filter' then @filter = params
    elsif hass_request?(cmd) then send(cmd, *params)
    else LOG.error([:unknown_cmd, cmd, req])
    end
  end

  private

  def connect_websocket
    ws_url = @address
    @hass_ws = Faye::WebSocket::Client.new(ws_url)

    @hass_ws.on :open do |_event|
      LOG.debug([:ws_connected])
    end

    @hass_ws.on :message do |event|
      handle_message(event.data)
    end

    @hass_ws.on :close do |event|
      LOG.debug([:ws_disconnected, event.code, event.reason])
    end

    @hass_ws.on :error do |event|
      LOG.error([:ws_error, event.message])
    end
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

    @client.puts(map_message(message).join)
  end

  def map_message(message)
    Array(message).map do |m|
      next unless m

      [m.to_s.gsub(POSTFIX, ''), POSTFIX]
    end
  end
end

# TCP Server that creates a Hass instance for each connected client
def start_tcp_server(hass_address, token, port = 8080)
  server = TCPServer.new(port)
  LOG.info([:server_started, port])

  loop do
    client = server.accept
    LOG.info([:client_connected, client.peeraddr])

    # Create a new Hass instance for the connected client
    EM.schedule do
      begin
        client.puts('welcome')
        hass_instance = Hass.new(hass_address, token, client)
        LOG.info([:hass_instance_created, hass_instance])
      rescue => e
        LOG.error([:client_error, e.message])
        client&.close unless client.closed?
      end
    end
  end
end

class ClientConnection < EM::Connection
  def initialize(hass_address, token)
    @hass_address = hass_address
    @token = token

    LOG.info([:client_connected, get_peername])

    # Create the Hass instance associated with this client
    @hass_instance = Hass.new(@hass_address, @token, self)
  end

  def post_init
    send_data("welcome\n")
  end

  def receive_data(data)
    data.chomp!
    LOG.debug([:from_savant, data])
    @hass_instance.from_savant(data)
  end

  def unbind
    LOG.debug([:savant_disconnected])
  end

  # Method to send data to the client
  def puts(data)
    send_data("#{data}\n")
  end
end

EM.run do
  # Start the TCP server within the reactor
  EM.start_server('0.0.0.0', TCP_PORT, ClientConnection, WS_URL, WS_TOKEN)
  LOG.info([:server_started, TCP_PORT])
end