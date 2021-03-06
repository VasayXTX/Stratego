#coding: utf-8

require 'validation'
require 'utils'
require File.join(File.dirname(__FILE__), '..', 'db', 'seeds')

#--------------------- Dynamic creation methods --------------------- 

def def_init(cl, *fields)
  cl.class_eval do 
    define_method(:initialize) do |req|
      super(req, fields)
    end
  end
end

#--------------------- DB module --------------------- 

module Database
  @@db_conn, @@db = '', ''

  module_function

  def self.set_db(db_conn, db)
    @@db_conn, @@db = db_conn, db
  end

  def exist?(coll, sel)
    @@db[coll].find(sel).count > 0
  end

  def get_user(sid)
    user = @@db['users'].find_one('sid' => sid)
    if user.nil?
      raise ResponseBadSession, 'Incorrect session id'
    end

    user
  end

  def get_by_name(coll, name, case_sensitive = false)
    sel = case_sensitive ? name : Regexp.new(name, true)
    res = @@db[coll].find_one('name' => sel)
    if res.nil?
      raise ResponseBadResource, 'Resource is\'t exist'
    end

    res
  end

  def get_by_id(coll, id)
    @@db[coll].find_one('_id' => id)
  end

  def check_access(user, res)
    unless user['_id'] == res['creator']
      raise ResponseBadAccess, 'Illegal access'
    end
  end

  def cur_to_arr(coll_name, sel, field)
    arr = []
    cur = @@db[coll_name].find(sel, :fields => [field])
    cur.each { |foo| arr << foo[field] }

    arr
  end

  def get_game_by_user(user_id)
    game = @@db['games'].find_one(
      { '$or' => [
        { 'creator'  => user_id },
        { 'opponent' => user_id }
      ] }
    )
    if game.nil?
      raise ResponseBadAction, 'User isn\'t player of this game'
    end
    if game['opponent'].nil?
      raise ResponseBadAction, 'The game isn\'t started'
    end

    game
  end
end

#--------------------- Cmd --------------------- 

class Cmd
  include Validations, Utils, Database

  MSGS = {
    :flds_num_l => 'Request has\'t enough fields for this command',
    :flds_num_g  => 'Request has extra fields for this command'
  }

  def initialize(req, fields)
    check_fields(req, fields)
  end

  def check_fields(req, fields)
    fields.each do |f|
      unless req.has_key?(f)
        raise ResponseBadCommand, MSGS[:flds_num_l]
      end
    end
    if req.size > fields.size
      raise ResponseBadCommand, MSGS[:flds_num_g]
    end
  end

  def encode(val, salt)
    Digest::SHA2.hexdigest("#{val}--#{salt}")
  end
  private :encode
end

#--------------------- Dev --------------------- 

class CmdDropDB < Cmd
  def_init self

  def handle(req)
    @@db_conn.drop_database(@@db.name)

    Seed.create_indexes(@@db)
    %w[units].each do |r|
      Seed.method("seed_#{r}".to_sym).call(@@db)
    end

    [{}, {}]
  end
end

#--------------------- Auth --------------------- 

class CmdSignup < Cmd
  def_init self, 'login', 'password'

  def handle(req)
    Validator.validate(@@db['users'], req, V_USER)

    t = Time.now.utc
    e_passw = encode(req['password'], t)
    sid = encode(req['login'], Time.now.utc)

    id = @@db['users'].insert({
      'login' => req['login'],
      'password' => e_passw,
      'status' => :online,
      'sid' => sid,
      'created_at' => t
    })

    [
      {
        'sid'   => sid,
        'login' => req['login']
      },
      {
        :all => {
          'cmd'   => 'addUserOnline',
          'login' => req['login']
        }
      },
      { 'reg' => id }
    ]
  end
end

class CmdLogin < Cmd
  def_init self, 'login', 'password'

  def handle(req)
    user = @@db['users'].find_one('login' => Regexp.new(req['login'], true))

    if user.nil?
      raise ResponseBadAction, 'Incorrect login'
    end

    e_passw = encode(req['password'], user['created_at'])
    unless e_passw == user['password']
      raise ResponseBadAction, 'Incorrect password'
    end

    sid = encode(user['login'], Time.now.utc)

    @@db['users'].update(
      { '_id'  => user['_id'] },
      { '$set' => { 'status' => :online, 'sid' => sid } }
    )

    [
      {
        'sid'   => sid,
        'login' => user['login']
      },
      {
        :all => {
          'cmd'   => 'addUserOnline',
          'login' => user['login']
        },
      },
      { 'reg' => user['_id'] }
    ]
  end
end

class CmdLogout < Cmd
  def_init self, 'sid'

  def handle(req)
    user = get_user(req['sid'])

    @@db['users'].update(
      { '_id' => user['_id'] },
      { '$set' => { 'status' => :offline } }
    )

    [
      {},
      {
        :all => {
          'cmd'   => 'delUserOnline',
          'login' => user['login']
        },
      },
      { 'unreg' => user['_id'] }
    ]
  end
end

class CmdCheckSid < Cmd
  def_init self, 'sid'

  def handle(req)
    user = get_user(req['sid'])
    [{}, {}, { 'reg' => user['_id'] }]
  end
end

class CmdGetUsersOnline < Cmd
  def_init self, 'sid'

  def handle(req)
    get_user(req['sid'])

    users = cur_to_arr(
      'users',
      { 'status' => :online },
      'login'
    )

    [{ 'users' => users }, {}, {}]
  end
end

#--------------------- Units ---------------------

class CmdGetAllUnits < Cmd
  def_init self, 'sid'

  def handle(req)
    user = get_user(req['sid'])

    units = {}
    @@db['units'].find().each do |u|
      units[u['name']] = {
        'rank'        => u['rank'],
        'moveLength'  => u['move_length'],
        'minCount'    => u['min_count'],
        'maxCount'    => u['max_count']
      }
    end

    [{ 'units' => units }, {}, {}]
  end
end

#--------------------- Maps --------------------- 

module Map
  include Database

  def check_map(width, height, struct)
    #Check values
    max_val = width * height
    check_value = ->(a) do
      a.each { |val| return false unless (0...max_val).include?(val) }
      true
    end

    #Check intersection
    check_intersection = ->(a1, a2) do
      (a1.select { |p| a2.include? p }).empty?
    end

    #Check unique values into arrays
    check_unique = ->(a) do
      h = Hash.new(0)
      a.each { |v| h[v] += 1; return false if h[v] > 1 }
      true
    end

    is_correct = 
      struct['pl1'].size == struct['pl2'].size &&
      struct['pl1'].size > 1

    is_correct &&=
      check_value.(struct['pl1']) &&
      check_value.(struct['pl2']) &&
      check_value.(struct['obst']) &&

    is_correct &&=
      check_unique.(struct['pl1']) &&
      check_unique.(struct['pl2']) &&
      check_unique.(struct['obst'])

    is_correct &&= 
      check_intersection.(struct['pl1'], struct['pl2']) &&
      check_intersection.(struct['pl1'], struct['obst']) &&
      check_intersection.(struct['pl2'], struct['obst'])

    raise ResponseBadMap, 'Incorrect map' unless is_correct
  end
end

class CmdCreateMap < Cmd
  include Map

  def_init self, 'sid', 'name', 'width', 'height', 'structure'

  def handle(req)
    Validator.validate(@@db['maps'], req, V_MAP)

    check_map(req['width'], req['height'], req['structure'])
    
    user = get_user(req['sid'])

    @@db['maps'].insert(
      {
        'name'       => req['name'],
        'creator'    => user['_id'],
        'created_at' => Time.now.utc
      }.merge(
        h_slice(req, %w[width height structure])
      )
    )

    [{},{},{}]
  end
end

class CmdEditMap < Cmd
  include Map

  def_init self, 'sid', 'name', 'width', 'height', 'structure'

  def handle(req)
    v_map = clone(V_MAP)
    v_map.delete('name')
    Validator.validate(@@db['maps'], req, v_map)

    check_map(req['width'], req['height'], req['structure'])
    
    user = get_user(req['sid'])
    map = get_by_name('maps', req['name'])
    check_access(user, map)

    @@db['maps'].update(
      { '_id' => map['_id'] },
      {
        '$set' => h_slice(req, %w[width height structure])
      }
    )

    [{},{},{}]
  end
end

class CmdDestroyMap < Cmd
  def_init self, 'sid', 'name'

  def handle(req)
    user = get_user(req['sid'])
    map = get_by_name('maps', req['name'])
    check_access(user, map)

    if @@db['tactics'].find('map' => map['_id']).count > 0
      raise ResponseBadAction, 'Map used in the tactics'
    end

    @@db['maps'].remove('_id' => map['_id'])

    [{},{},{}]
  end
end

class CmdGetListMaps < Cmd
  def_init self, 'sid'

  def handle(req)
    user = get_user(req['sid'])
    maps = cur_to_arr('maps', get_selector(user), 'name')

    [{ 'maps' => maps },{},{}]
  end

  def get_selector(user)
    { 'creator' => user['_id'] }
  end
  private :get_selector
end

class CmdGetListAllMaps < CmdGetListMaps
  def get_selector(user); {}; end
  private :get_selector
end

class CmdGetMapParams < Cmd
  def_init self, 'sid', 'name'

  def handle(req)
    get_user(req['sid'])
    map = get_by_name('maps', req['name'])

    [h_slice(map, %w[width height structure]),{},{}]
  end
end

#--------------------- Armies --------------------- 

module Army
  include Database

  ERR_MSG = 'Incorrect army'

  def check_army(units)
    raise ResponseBadArmy, ERR_MSG if units.empty?

    common_move_lengths = 0
    existsing = {}
    units.each_pair do |army_unit, count|
      u = @@db['units'].find_one('name' => army_unit)
      raise ResponseBadArmy, ERR_MSG if u.nil?

      r = u['min_count']..u['max_count']
      raise ResponseBadArmy, ERR_MSG unless r.include?(count)

      common_move_lengths += u['move_length']
      existsing[u['name']] = true
    end

    correct_existing = existsing['Bomb'] ? existsing['Miner'] : true

    if common_move_lengths == 0 || !correct_existing
      raise ResponseBadArmy, ERR_MSG
    end

    common_count = units.values()
  end
end

class CmdCreateArmy < Cmd
  include Army

  def_init self, 'sid', 'name', 'units'

  def handle(req)
    Validator.validate(@@db['armies'], req, V_ARMY)

    check_army(req['units'])
    
    user = get_user(req['sid'])

    @@db['armies'].insert(
      'name'       => req['name'],
      'creator'    => user['_id'],
      'units'      => req['units'],
      'created_at' => Time.now.utc
    )

    [{},{},{}]
  end
end

class CmdEditArmy < Cmd
  include Army

  def_init self, 'sid', 'name', 'units'

  def handle(req)
    check_army(req['units'])
    
    user = get_user(req['sid'])
    army = get_by_name('armies', req['name'])
    check_access(user, army)

    @@db['armies'].update(
      { '_id'  => army['_id'] },
      { '$set' => { 'units' => req['units'] } }
    )

    [{},{},{}]
  end
end

class CmdDestroyArmy < Cmd
  def_init self, 'sid', 'name'

  def handle(req)
    user = get_user(req['sid'])
    army = get_by_name('armies', req['name'])
    check_access(user, army)

    if @@db['tactics'].find('army' => army['_id']).count > 0
      raise ResponseBadAction, 'Army used in the tactics'
    end

    @@db['armies'].remove('_id' => army['_id'])

    [{},{},{}]
  end
end

class CmdGetListArmies < Cmd
  def_init self, 'sid'

  def handle(req)
    user = get_user(req['sid'])
    armies = cur_to_arr('armies', get_selector(user), 'name')

    [{ 'armies' => armies },{},{}]
  end

  def get_selector(user)
    { 'creator' => user['_id'] }
  end
  private :get_selector
end

class CmdGetListAllArmies < CmdGetListArmies
  def get_selector(user); {}; end
  private :get_selector
end

class CmdGetArmyUnits < Cmd
  def_init self, 'sid', 'name'

  def handle(req)
    user = get_user(req['sid'])
    army = get_by_name('armies', req['name'])

    units = army['units']
    units.each_pair do |u_name, u_count|
      unit = @@db['units'].find_one('name' => u_name)
      units[u_name] = {
        'count'      => u_count,
        'minCount'   => unit['min_count'],
        'maxCount'   => unit['max_count'],
        'moveLength' => unit['move_length']
      }
    end

    [{ 'units' => units },{},{}]
  end
end

#--------------------- Games --------------------- 

module Game
  include Database

  ERR_MSG = 'Incorrect game'
  ERR_MSG_MOVE = 'Incorrect move'

  def check_game(map, army)
    units_count = army['units'].values.reduce(:+)
    unless units_count == map['structure']['pl1'].size
      raise ResponseBadGame, ERR_MSG
    end
  end

  def check_user(user_id)
    sel = {
      '$or' => [{ 'creator' => user_id }, { 'opponent' => user_id }]
    }
    if exist?('games', sel)
      raise ResponseBadAction, 'User already in a game'
    end
  end

  def reflect_placement(placement, s)
    h = {}
    placement.each_pair { |k, v| h[(s - k.to_i - 1).to_s] = v }

    h
  end

  def check_placement(placement, pl, map, army_units)
    positions = placement.keys.map { |p| p.to_i }
    units = Hash.new(0)
    placement.values.each { |u| units[u] += 1 }

    res = positions.sort == map['structure'][pl].sort &&
      units == army_units

    unless res
      raise ResponseBadPlacement, 'Incorrect placement'
    end
  end

  def turn?(game, is_pl1)
    pl1, pl2 = game['moves']['pl1'].size, game['moves']['pl2'].size
    is_pl1 ? pl1 == pl2 : pl1 > pl2
  end

  def reflect_pos(p, map)
    s = map['width'] * map['height']
    s - p - 1
  end
end

class CmdCreateGame < Cmd
  include Game

  def_init self, 'sid', 'name', 'nameMap', 'nameArmy'
  def handle(req)
    Validator.validate(@@db['games'], req, V_GAME)

    user = get_user(req['sid'])
    check_user(user['_id'])

    map  = get_by_name('maps', req['nameMap'])
    army = get_by_name('armies', req['nameArmy'])

    check_game(map, army)

    map_fields = %w[_id name width height structure]
    army_fields = %w[_id name units]
    @@db['games'].insert(
      'name'       => req['name'],
      'creator'    => user['_id'],
      'map'        => h_slice(map, map_fields),
      'army'       => h_slice(army, army_fields),
      'created_at' => Time.now.utc
    )
    
    [
      {},
      {
        :all => {
          'cmd'  => 'addAvailableGame',
          'name' => req['name']
        }
      },
      {}
    ]
  end
end

class CmdGetGameParams < Cmd
  def_init self, 'sid', 'name'

  def handle(req)
    get_user(req['sid'])

    game = get_by_name('games', req['name'])
    map  = h_slice(game['map'], %w[name width height structure])
    army = h_slice(game['army'], %w[name units])
    
    [{ 'map' => map, 'army' => army }, {}, {}]
  end
end

class CmdGetAvailableGames < Cmd
  def_init self, 'sid'

  def handle(req)
    get_user(req['sid'])
    games = cur_to_arr(
      'games',
      { 'opponent' => { '$exists' => false } },
      'name'
    )
    
    [{ 'games' => games }, {}, {}]
  end
end

class CmdDestroyGame < Cmd
  def_init self, 'sid'

  def handle(req)
    user = get_user(req['sid'])
    game = @@db['games'].find_one('creator' => user['_id'])

    if game.nil?
      raise ResponseBadAction, 'User hasn\'t created any game'
    end
    if game['opponent']
      raise ResponseBadAction, 'Game already started'
    end

    name_game = game['name']
    @@db['games'].remove('_id' => game['_id'])

    [{}, { :all => { 'cmd' => 'delAvailableGame', 'name' => name_game } }, {}]
  end
end

class CmdJoinGame < Cmd
  include Game

  def_init self, 'sid', 'name'

  def handle(req)
    user = get_user(req['sid'])
    check_user(user['_id'])

    game = get_by_name('games', req['name'])
    
    unless game['opponent'].nil?
      raise ResponseBadAction, 'The game isn\'t available'
    end

    @@db['games'].update(
      { '_id'  => game['_id'] },
      { '$set' => { 'opponent' => user['_id'] } }
    )
  
    [
      {},
      { 
        game['creator'] => {
          'cmd' => 'startGamePlacement'
        },
        :all => {
          'cmd'  => 'delAvailableGame',
          'name' => game['name']
        }
      },
      {}
    ]
  end
end

class CmdLeaveGame < Cmd
  def_init self, 'sid'

  def handle(req)
    user = get_user(req['sid'])
    game = get_game_by_user(user['_id'])

    second_user = user['_id'] == game['creator'] ? 
      game['opponent'] : game['creator']

    @@db['games'].remove('_id' => game['_id'])

    [{}, { second_user => { 'cmd' => 'endGame' } }, {}]
  end
end

class CmdGetGame < Cmd
  include Game

  def_init self, 'sid'

  def prepare_process(game, is_pl1, pl, opp)
    map = game['map']

    s = map['width'] * map['height']
    p = game['placement']

    is_placed = !game['placement'].nil? && !game['placement'][pl].nil?

    reflect_a = ->(a) { a.map! { |el| s - el.to_i - 1 } }

    m = h_slice(map, %w[name width height])
    m['obst'] = map['structure']['obst']

    st = [
      is_placed ? p[pl] : map['structure'][pl],
      is_placed && p[opp] ? p[opp].keys.map { |el| el.to_i } : map['structure'][opp]
    ]

    unless is_pl1
      reflect_a.(m['obst'])
      if is_placed
        st[0] = reflect_placement(st[0], s)
      else
        reflect_a.(st[0])
      end
      reflect_a.(st[1])
    end

    resp = {
      'state' => {
        'pl1' => st[0],
        'pl2' => st[1]
      },
      'map' => m
    }

    if game['moves']
      resp['isTurn'] = turn?(game, is_pl1)

      units_pl, units_opp = Hash.new(0), Hash.new(0)
      game['placement'][pl].values.each { |u| units_pl[u] += 1 }
      game['placement'][opp].values.each { |u| units_opp[u] += 1 }
      resp['units'] = { 'pl1' => units_pl, 'pl2' => units_opp }
    end

    resp
  end

  def handle(req)
    user = get_user(req['sid'])
    game = get_game_by_user(user['_id'])

    is_pl1 = user['_id'] == game['creator']
    pl, opp = is_pl1 ? %w[pl1 pl2] : %w[pl2 pl1]

    resp = prepare_process(game, is_pl1, pl, opp)

    resp['game_name'] = game['name']

    army = game['army']
    units = {}
    army['units'].each_pair do |u_name, u_count|
      u = @@db['units'].find_one('name' => u_name)
      units[u_name] = {
        'count'      => u_count,
        'moveLength' => u['move_length']
      }
    end
    resp['army'] = { 'name'  => army['name'], 'units' => units }

    get_login = ->(user_id) do
      @@db['users'].find_one('_id' => user_id)['login']
    end
    resp['players'] = is_pl1 ?
      [user['login'], get_login.(game['opponent'])] :
      [get_login.(game['creator']), user['login']]

    [resp, {}, {}]
  end
end

class CmdSetPlacement < Cmd
  include Game

  def_init self, 'sid', 'placement'

  def handle(req)
    user = get_user(req['sid'])
    game = get_game_by_user(user['_id'])

    unless game['moves'].nil?
      raise ResponseBadAction, 'Game has already started'
    end

    map = game['map']
    pl, opp =
      if user['_id'] == game['creator']
        %w[pl1 opponent]
      else
        req['placement'] = reflect_placement(
          req['placement'],
          map['width'] * map['height']
        )
        %w[pl2 creator]
      end

    r, r_opp =
      if p = game['placement']
        raise ResponseBadAction, 'Already placed' if p[pl]
        [true, 'startGame' ]
      else
        [false, 'readyOpponent']
      end
                                            
    check_placement(
      req['placement'], pl, map, game['army']['units'])
    
    c_update = { "placement.#{pl}" => req['placement'] }
    c_update['moves'] = { 'pl1' => [], 'pl2' => [] } if r
    @@db['games'].update(
      { '_id'  => game['_id'] },
      { '$set' => c_update }
    )

    [
      { 'isGameStarted' => r },
      { game[opp] => { 'cmd' => r_opp } },
      {}
    ]
  end
end

class CmdMakeMove < Cmd
  include Game

  def_init self, 'sid', 'posFrom', 'posTo'

  def handle(req)
    user = get_user(req['sid'])
    game = get_game_by_user(user['_id'])

    if game['moves'].nil?
      raise ResponseBadAction, 'Game isn\'t started'
    end

    is_pl1 = user['_id'] == game['creator']

    unless turn?(game, is_pl1)
      raise ResponseBadAction, 'It isn\'t your turn now'
    end
    
    pl1, pl2, opp = is_pl1 ? %w[pl1 pl2 opponent] : %w[pl2 pl1 creator]
    opp_id = game[opp]

    map = game['map']

    pl_duel, opp_duel, is_end = make_move(
      game, map, req['posFrom'], req['posTo'], is_pl1)

    pl_resp, opp_resp = [pl_duel, opp_duel].map { |d| d.empty? ? {} : { 'duel' => d } }

    opp_resp.merge!(
      'cmd'     => 'opponentMakeMove',
      'posFrom' => reflect_pos(req['posFrom'], map),
      'posTo'   => reflect_pos(req['posTo'], map)
    )

    if is_end
      pl_resp['isEnd']  = true
      opp_resp['isEnd'] = true
    end

    [pl_resp, { opp_id => opp_resp }, {}]
  end

  def check_positions(p_from, p_to, pl_positions, map)
    #Ok, if player move to space or opponent cell
    
    r = 0...(map['width'] * map['height'])

    cond = 
      r.include?(p_from) &&
      r.include?(p_to) &&
      pl_positions.include?(p_from) &&
      !pl_positions.include?(p_to) &&
      !map['structure']['obst'].include?(p_to)

    raise ResponseBadMove, ERR_MSG_MOVE unless cond
  end

  def check_move(p_from, p_to, map, placement, unit)
    pos_to_cord = ->(p) { [p % map['width'], p / map['width']] }
    x_from, y_from = pos_to_cord.(p_from)
    x_to, y_to     = pos_to_cord.(p_to)

    check_line = ->(c_from, c_to, dir) do
      m_len = (c_to - c_from).abs
      if m_len > unit['move_length']
        raise ResponseBadMove, ERR_MSG_MOVE
      end

      sign = c_to - c_from <=> 0
      k = dir == :v ? map['width'] : 1
      1.upto(m_len - 1) do |i|
        p = p_from + i * k * sign

        is_failed =
          map['structure']['obst'].include?(p) ||
          placement['pl1'].include?(p) ||
          placement['pl2'].include?(p)

        raise ResponseBadMove, ERR_MSG_MOVE if is_failed
      end
    end

    if x_from == x_to
      check_line.(y_from, y_to, :v)
    elsif y_from == y_to
      check_line.(x_from, x_to, :h)
    else
      raise ResponseBadMove, ERR_MSG_MOVE
    end
  end

  def calc_duel(pl_unit, opp_unit)
      duel = {
        'attacker'  => pl_unit['name'],
        'protector' => opp_unit['name'],
      }
      duel_opp = clone(duel)
      
      pl_win_duels  = pl_unit['win_duels']['attack']
      opp_win_duels = opp_unit['win_duels']['protect']
      
      duel['result'], duel_opp['result'] = 
        if pl_win_duels.include?(opp_unit['_id'])
          [:win, :loss]
        elsif opp_win_duels == :all || opp_win_duels.include?(pl_unit['_id'])
          [:loss, :win]
        else
          h = { 1 => :win, -1 => :loss, 0 => :draw }
          [
            h[pl_unit['rank']  <=> opp_unit['rank']],
            h[opp_unit['rank'] <=> pl_unit['rank']]
          ]
        end

      [duel, duel_opp, opp_unit['name'] == 'Flag']
  end

  def make_move(game, map, p_from, p_to, is_pl1)
    pl, opp = is_pl1 ? %w[pl1 pl2] : %w[pl2 pl1]

    unless is_pl1
      p_from = reflect_pos(p_from, map)
      p_to = reflect_pos(p_to, map)
    end

    pl_placement  = game['placement'][pl]
    opp_placement = game['placement'][opp]
    pl_positions  = pl_placement.keys.map { |el| el.to_i }
    opp_positions = opp_placement.keys.map { |el| el.to_i }

    check_positions(p_from, p_to, pl_positions, map)

    unit_name = pl_placement[p_from.to_s]
    pl_unit = get_by_name('units', unit_name)

    check_move(p_from, p_to, map, game['placement'], pl_unit)
    
    pl_duel, opp_duel, is_end = {}, {}, false
    if opp_positions.include?(p_to)
      unit_name = opp_placement[p_to.to_s]
      opp_unit = get_by_name('units', unit_name)

      pl_duel, opp_duel, is_end = calc_duel(pl_unit, opp_unit)

      if pl_duel['result'] == :win
        opp_placement.delete(p_to.to_s) 
        pl_placement[p_to.to_s] = pl_unit['name'];
      elsif pl_duel['result'] == :draw
        opp_placement.delete(p_to.to_s)
      end
    else
      pl_placement[p_to.to_s] = pl_unit['name']
    end

    if is_end
      @@db['games'].remove('_id' => game['_id'])
    else
      moves = game['moves'][pl]
      moves << {
        'pos_from'   => p_from,
        'pos_to'     => p_to,
        'created_at' => Time.now.utc
      }

      pl_placement.delete(p_from.to_s)

      @@db['games'].update(
        { '_id'  => game['_id'] },
        { '$set' =>
          {
            'moves'     => game['moves'],
            'placement' => game['placement']
          }
        }
      )
    end

    [pl_duel, opp_duel, is_end]
  end
end

#--------------------- Tactics --------------------- 

class CmdCreateTactic < Cmd
  include Game

  def_init self, 'sid', 'name', 'nameMap', 'nameArmy', 'placement'

  def handle(req)
    Validator.validate(@@db['tactics'], req, V_TACTIC)

    user = get_user(req['sid'])

    map  = get_by_name('maps', req['nameMap'])
    check_access(user, map)
    army = get_by_name('armies', req['nameArmy'])
    check_access(user, army)

    %w[pl1 pl2].each do |pl|
      check_placement(
        req['placement'][pl], pl, map, army['units'])
    end

    @@db['tactics'].insert(
      'name'       => req['name'],
      'creator'    => user['_id'],
      'map'        => map['_id'],
      'army'       => army['_id'],
      'placement'  => req['placement'],
      'created_at' => Time.now.utc
    )

    [{},{},{}]
  end
end

class CmdGetGameTactics < Cmd
  def_init self, 'sid'

  def handle(req)
    user = get_user(req['sid'])
    game = get_game_by_user(user['_id'])

    pl = game['creator'] == user['_id'] ? 'pl1' : 'pl2'

    db_tactics = @@db['tactics'].find(
      'map'  => game['map']['_id'],
      'army' => game['army']['_id']
    )
    tactics = Hash.new
    db_tactics.each { |t| tactics[t['name']] = t['placement'][pl] }

    [{ 'tactics' => tactics },{},{}]
  end
end
