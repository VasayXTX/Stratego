#coding: utf-8

%w[
  eventmachine
  em-websocket-client
  json
  yaml
  logger
].each { |gem_file| require gem_file }

require './simple_ai.rb'
require './printer.rb'

module Commands
  private

  def cmd_login
    {
      cmd: 'login',
      login: @login,
      password: @passw
    }
  end

  def cmd_logout
    { cmd: 'logout' }
  end

  def cmd_create_game
    {
      cmd: 'createGame',
      name: @game['name'],
      nameMap: @game['map'],
      nameArmy: @game['army']
    }
  end

  def cmd_destroy_game
    { cmd: 'destroyGame' }
  end

  def cmd_leave_game
    { cmd: 'leaveGame' }
  end

  def cmd_join_game
    { cmd: 'joinGame', name: @game['name'] }
  end

  def cmd_set_placement(placement)
    { cmd: 'setPlacement', placement: placement }
  end

  def cmd_make_move(pos_from, pos_to)
    { cmd: 'makeMove', posFrom: pos_from, posTo: pos_to }
  end
end

#--------------- Ai Client ---------------

class AiClient
  def self.run(host, port, ai_player, log_file)
    File.delete(log_file) if File.exist?(log_file)
    log = Logger.new(log_file)

    is_end = false

    EM.run do
      conn = EventMachine::WebSocketClient.connect("ws://#{host}:#{port}/")

      conn.callback do
        req = ai_player.start
        log.debug("Request: #{req}")
        conn.send_msg(req.to_json)
      end

      conn.stream do |data|
        resp = JSON.parse(data)
        log.debug("Response: #{resp}")

        status = resp.delete('status')
        if (status && status != 'ok') || is_end
          log.close
          EM::stop_event_loop
        else
          req, is_end = ai_player.handle(resp)
          if !req.nil? && req.size > 1             # Empty or sid only
            log.debug("Request: #{req}")
            conn.send_msg(req.to_json)
          end
        end
      end

      conn.disconnect do
        puts 'By!'
        log.close
        EM::stop_event_loop
      end
    end
  end
end

#--------------- Ai Player ---------------

class AiPlayer
  include Commands
  include SimpleAi
  include Printer

  def initialize(user_opts, game, out)
    @login = user_opts['login']
    @passw = user_opts['password']
    @is_creator = user_opts['is_creator']
    @game = game
    @out = out

    @moves_counter = 0

    @fb = Fiber.new do
      # Fiber.yield({}) - wait action from second player

      # Login
      resp = Fiber.yield(cmd_login)
      @sid = resp['sid']
       
      # Create/Join game
      if @is_creator
        Fiber.yield(cmd_create_game)
        Fiber.yield({})
      else
        Fiber.yield(cmd_join_game)
      end
      
      # Placement
      placement = {}
      if (t = @game['tactic']).instance_of?(Hash)
        t.each_pair { |k, v| v.each { |p| placement[p.to_s] = k } }
      end
      resp = Fiber.yield(cmd_set_placement(placement))
      Fiber.yield({}) unless resp['isGameStarted']

      # Make move
      cur_game = Fiber.yield({ cmd: 'getGame' })
      parse_game(cur_game)
      l = [
        (-> do 
          @moves_counter += 1
          # sleep(1)
          resp = Fiber.yield(make_move)
          process_duel(resp)
          print_game_info
          resp['isEnd']
        end),
        (-> do
          opp_move = Fiber.yield({})
          process_opponent_move(opp_move)
          print_game_info
          opp_move['isEnd']
        end)
      ]
      l.reverse! unless @is_turn
      loop do
        break if l[0].() || l[1].()
      end

      # Logout
      Fiber.yield(cmd_logout)
    end
  end

  def start
    @fb.resume
  end

  def handle(resp)
    prepare_req = ->(req) do
      is_logout = req[:cmd] == 'logout' ? true : false
      req[:sid] = @sid
      [req, is_logout]
    end

    if resp.has_key?('cmd')
      case resp['cmd']
      when 'startGamePlacement'
        return prepare_req.(@fb.resume)
      when 'endGame'
        return prepare_req.(cmd_logout)
      when 'startGame'
        return prepare_req.(@fb.resume)
      when 'opponentMakeMove'
        return prepare_req.(@fb.resume(resp))
      end
      return
    end

    prepare_req.(@fb.resume(resp))
  end

  private

  #--------- Private methods ---------

  def print_game_info
    @out.print('-' * 10  + @moves_counter.to_s + '-' * 10 + "\n")
    @out.print(draw_game_state)
    @out.print("\n\n")
    # @out.print('Opponent units:')
    # @out.print(pp_hash(@opp_state, 1))
    # @out.print('My units')
    # @out.print(pp_hash(@my_state))
    @out.flush
  end
end

config = YAML.load_file(ARGV[0] || 'config.yml')

game_outer = File.open(config['game_process_file'], 'w')

ai_player = AiPlayer.new(
  config['user'],
  config['game'],
  game_outer
)

AiClient.run(
  config['ws_server']['host'],
  config['ws_server']['port'],
  ai_player,
  config['log_file']
)

game_outer.close
