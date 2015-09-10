# coding: utf-8
require 'capybara'
require 'capybara/dsl'
require 'capybara/poltergeist'
require 'yaml'
require 'open-uri'

Capybara.configure do |config|
  config.run_server = false
  config.current_driver = :poltergeist
  config.javascript_driver = :poltergeist
  config.app_host = 'https://p.eagate.573.jp'
  config.default_wait_time = 15
end

Capybara.register_driver :poltergeist do |app|
  Capybara::Poltergeist::Driver.new(app, js_errors: false, phantomjs_logger: File.open(File::NULL, 'w'))
end


module Crawler
  class Gitadora
    include Capybara::DSL

    CRAWL_DELAY = 3
    SEPARATOR = '.'
    GTYPES = {guitar: 'gf', drum: 'dm'}
    DIFFICULTY_ABBREVS = {'BASIC' => 'BSC', 'ADVANCED' => 'ADV', 'EXTREME' => 'EXT', 'MASTER' => 'MAS'}

    def initialize
      login
      extract_levels
      @gdsa = Gdsa.new
    end

    def extract_levels
      res = open('http://gfdm-analyzer.com/musics.json')
      @levels = JSON.parse(res.read)
    end

    def login
      visit('/gate/p/login.html')
      config = YAML.load_file('config.yml')
      fill_in 'KID', with: config['Gitadora']['id']
      fill_in 'pass', with: config['Gitadora']['password']
      click_button '規約に同意してログイン'
    end

    # game は :drum か :guitar
    def view(game, category)
      gtype = GTYPES[game]
      visit("/game/gfdm/gitadora_tb/p/eam/playdata/music.html?gtype=#{gtype}")

      select category, from: 'cat'
      click_button '表示'
    end

    def crawl(game)
      links = page.all('a.text_link').map {|a| a[:href] }
      links.each do |url|
        sleep CRAWL_DELAY

        visit(url)

        title = page.find('.live_title').text.tr('！', '!')
        print "  #{title}: "

        # 達成率、レベル、難易度をそれぞれ収集して配列作成 (同じインデックスどうしで対応する)
        tables = page.all('.md')
        achievements = tables.map {|div| div.all('tbody tr')[3].all('td')[1].text.to_f }
        if achievements.all? {|f| f.zero? }
          puts '1 度もプレイしていないためスキップしました。'
          next
        end

        levels = page.all('.diff_area').map {|l| l.text.to_f }
        difficulties = tables.map{|div| div.first('thead tr th')[:class] }.map{|str| str.slice!('diff_'); str }
        if game == :guitar
          current_prefix = 'GUITAR'
          prefixes = [current_prefix]
          difficulties.each_cons(2) do |a, b|
            current_prefix = 'BASS' if DIFFICULTY_ABBREVS.keys.index(a) > DIFFICULTY_ABBREVS.keys.index(b)
            prefixes << current_prefix
          end

          diffs = []
          prefixes.zip(difficulties) {|a| diffs << a.join(SEPARATOR) }
          difficulties = diffs
        end

        # スキル対象のレベルの決定
        si = levels.zip(achievements).map {|a, b| a * b }.each_with_index.max[1]
        sd = difficulties[si]
        if sd.index(SEPARATOR)
          split = sd.split(SEPARATOR)
          game = split[0]
          difficulty = split[1]
        else
          game = 'Drum'
          difficulty = sd
        end

        game.capitalize!
        difficulty = DIFFICULTY_ABBREVS[difficulty]

        # 全曲リストに登録されているか確認
        unless defined? @levels[title][game][difficulty]
          puts '曲もしくは難易度が GDSA に登録されていないためスキップしました。'
          next
        end

        @gdsa.register(title, game, difficulty, achievements[si])
        puts "#{game}(#{difficulty}) に達成率 #{achievements[si]} % を登録しました。"
      end
    end

    def point(achievement, level)
      (achievement / 100.0) * level * 20.0
    end
  end


  class Gdsa
    include Capybara::DSL

    def initialize
      login
    end

    def login
      visit('http://gfdm-analyzer.com/users/sign_in')
      config = YAML.load_file('config.yml')
      fill_in 'user[email]', with: config['GDSA']['id']
      fill_in 'user[password]', with: config['GDSA']['password']
      click_button 'Log in'
    end

    def register(music, game, difficulty, achievement)
      visit('http://gfdm-analyzer.com/skills/new')
      select game, from: 'mst_level[mst_game_id]'
      select music, from: 'mst_level[mst_music_id]'
      select difficulty, from: 'mst_level[mst_difficulty_id]'
      fill_in 'skill[achievement]', with: achievement
      click_button 'Create Skill'
    end
  end
end


GAMES = [:guitar, :drum]
CATEGORIES = ['数字・記号'] +
             ('A'..'Z').to_a +
             %w(あ か さ た な は ま や ら わ).map {|s| s + '行' }


config = YAML.load_file('config.yml')

crawler = Crawler::Gitadora.new
GAMES.each do |game|
  next if game == :guitar and not config['Config']['sync_guitar']
  next if game == :drum and not config['Config']['sync_drum']

  puts "[#{game}]"
  CATEGORIES.each do |category|
    crawler.view(game, category)
    crawler.crawl(game)
  end
end
