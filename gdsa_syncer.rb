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
      visit('/gate/p/login.html?path=%2Fgame%2Fgfdm%2Fgitadora%2Fp%2Fcont%2Fplay_data_tb%2Fmusic.html')
      config = YAML.load_file('config.yml')
      fill_in 'KID', with: config['Gitadora']['id']
      fill_in 'pass', with: config['Gitadora']['password']
      click_button '規約に同意してログイン'
    end

    # game: 'GuitarFreaks' or 'DrumMania'
    def view(game, category)
      visit('/game/gfdm/gitadora/p/cont/play_data_tb/music.html')

      click_link(game)
      select category, from: 'cat'
      click_button '表示'
    end

    def crawl
      links = page.all('a.text_link').map {|a| a[:href] }
      links.each do |url|
        visit(url)

        # 各難易度の達成率の収集
        # (ドラム: {"BASIC": 85.03, ...},  ギター: {"GUITAR.BASIC": 72.65, ..., "BASE.BASIC": 91.12, ...})
        title = page.find('.live_title').text.tr('！', '!')
        difficulties = page.all('.index_md_tb').map {|div| div.all('font').map{|f| f.text }.reject{|s| s.empty? }.join(SEPARATOR) }
        achievements = page.all('.md').map {|div| div.all('tbody tr')[3].all('td')[1].text.to_f }
        results = Hash[difficulties.zip achievements].reject {|k,v| v.zero? }

        print "  #{title}: "

        # 各曲のスキル対象の決定
        achievements = {}
        results.each do |k, v|
          if k.index(SEPARATOR)
            split = k.split(SEPARATOR)
            game = split[0]
            difficulty = split[1]
          else
            game = 'Drum'
            difficulty = k
          end

          game.capitalize!
          difficulty = DIFFICULTY_ABBREVS[difficulty]

          # 全曲リストに登録されているか確認
          unless defined? @levels[title][game][difficulty]
            achievements = {}
            print '曲もしくは難易度が GDSA に登録されていません。'
            break
          end

          achievements["#{game}#{SEPARATOR}#{difficulty}"] = v
        end

        # スキルが最大のもののみ extracted に登録
        mk, mv = achievements.max_by do |k,v|
          game, difficulty = k.split(SEPARATOR)
          point(v, @levels[title][game][difficulty])
        end

        if mk.nil?
          puts 'スキップしました。'
        else
          game, difficulty = mk.split('.')
          @gdsa.register(title, game, difficulty, achievements[mk])
          puts "#{game}(#{difficulty}) に達成率 #{achievements[mk]} % を登録しました。"
        end

        sleep CRAWL_DELAY
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


GAMES = ['GuitarFreaks', 'DrumMania']
CATEGORIES = ['数字・記号'] +
             ('A'..'Z').to_a +
             %w(あ か さ た な は ま や ら わ).map {|s| s + '行' }


config = YAML.load_file('config.yml')

crawler = Crawler::Gitadora.new
GAMES.each do |game|
  next if game == 'GuitarFreaks' and not config['Config']['sync_guitar']
  next if game == 'DrumMania' and not config['Config']['sync_drum']

  puts "[#{game}]"
  CATEGORIES.each do |category|
    crawler.view(game, category)
    crawler.crawl
  end
end
