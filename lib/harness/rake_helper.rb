require "yaml"
require "interact"
require "harness"
require "curb"
require "mongo"
require "yajl"
require "digest/md5"
require "tempfile"

module BVT::Harness
  module RakeHelper
    include Interactive, ColorHelpers

    VCAP_BVT_DEFAULT_TARGET =   "vcap.me"
    VCAP_BVT_DEFAULT_USER   =   "test@vcap.me"
    VCAP_BVT_DEFAULT_ADMIN  =   "admin@vcap.me"

    def generate_config_file(user='normal')
      Dir.mkdir(VCAP_BVT_HOME) unless Dir.exists?(VCAP_BVT_HOME)
      get_config

      get_target
      if user == 'normal'
        get_user
        get_user_passwd
      elsif user == 'admin'
        get_admin_user
        get_admin_user_passwd
      end

      save_config
    end

    def check_environment
      check_network_connection
      client = BVT::Harness::CFSession.new(:email => $target_config['user']['email'],
                                           :passwd => $target_config['user']['passwd'],
                                           :target => $target_config['target'])
      profile = {}
      profile[:runtimes] = client.system_runtimes
      profile[:services] = client.system_services
      profile[:frameworks] = client.system_frameworks
      profile[:script_hash] = get_script_git_hash
      $vcap_bvt_profile_file ||= File.join(BVT::Harness::VCAP_BVT_HOME,
                                           "profile.#{$target_config['target']}.yml")
      File.open($vcap_bvt_profile_file, "w") { |f| f.write YAML.dump(profile) }

      # clear parallel env
      ENV.delete('YETI_PARALLEL_USER')
      ENV.delete('YETI_PARALLEL_USER_PASSWD')
    end

    def check_network_connection
      easy = Curl::Easy.new
      easy.url = "http://api.#{@config['target']}/info"
      easy.resolve_mode = :ipv4
      easy.timeout = 10
      begin
        easy.http_get
      rescue Curl::Err::CurlError
        raise RuntimeError,
              red("Cannot connect to target environment, #{easy.url}\n" +
                      "Please check your network connection to target environment.")
      end
      unless easy.response_code == HTTP_RESPONSE_CODE::OK
        raise RuntimeError,
              red("URL: #{easy.url} response code does not equal to " +
                      "#{HTTP_RESPONSE_CODE::OK}\nPlease check your target environment first.")
      end
    end

    def cleanup!
      get_config
      get_target
      get_user
      get_user_passwd
      save_config
      check_network_connection
      cleanup_services_apps(@config['user']['email'], @config['user']['passwd'])
      user_info = get_config
      if user_info['parallel']
        user_info['parallel'].each do |puser|
          cleanup_services_apps(puser['email'], puser['passwd'])
        end
      end
    end

    def sync_assets
      downloads = get_assets_info
      if downloads == nil
        raise RuntimeError,
          red("Get remote file list faild, might be caused by unstable network.\n" +
              "Please try again.")
      end
      if File.exist?(VCAP_BVT_ASSETS_PACKAGES_MANIFEST)
        locals = YAML.load_file(VCAP_BVT_ASSETS_PACKAGES_MANIFEST)['packages']
      else
        locals = []
      end
      puts "check local assets binaries"
      skipped = []
      unless locals.empty?
        total = locals.length
        locals.each_with_index do |item, index|
          downloads_index = downloads.index {|e| e['filename'] == item['filename']}
          index_str = "[#{(index + 1).to_s}/#{total.to_s}]"
          if downloads_index
            if downloads[downloads_index]['md5'] == item['md5']
              puts green("#{index_str}Skipped\t\t#{item['filename']}")
              downloads.delete_at(downloads_index)
              skipped << Hash['filename' => item['filename'], 'md5' => item['md5']]
            else
              puts yellow("#{index_str}Need to update\t#{item['filename']}")
            end
          else
            puts red("#{index_str}Remove\t\t#{item['filename']}")
            File.delete(File.join(VCAP_BVT_ASSETS_PACKAGES_HOME, item['filename']))
          end
        end
      end

      unless downloads.empty?
        puts "\ndownloading assets binaries"
        Dir.mkdir(VCAP_BVT_ASSETS_PACKAGES_HOME) unless Dir.exist?(VCAP_BVT_ASSETS_PACKAGES_HOME)
        total = downloads.length
        downloads.each_with_index do |item, index|
          index_str = "[#{(index + 1).to_s}/#{total.to_s}]"
          filepath = File.join(VCAP_BVT_ASSETS_PACKAGES_HOME, item['filename'])
          puts yellow("#{index_str}downloading\t#{item['filename']}")
          download_binary(filepath)
          unless check_md5(filepath) == item['md5']
            puts red("#{index_str}fail to download\t\t#{item['filename']}.\n"+
                     "Might be caused by unstable network, please try again.")
          end
          skipped << Hash['filename' => item['filename'], 'md5' => item['md5']]
          File.open(VCAP_BVT_ASSETS_PACKAGES_MANIFEST, "w") do |f|
            f.write YAML.dump(Hash['packages' => skipped])
          end
        end
      end
      puts green("sync assets binaries finished")
    end

    def print_test_config
      puts yellow("\n\nBVT is starting...")
      puts "target: \t#{yellow(@config['target'])}"
      puts "admin user: \t#{yellow(@config['admin']['email'])}" if @config['admin']
      puts "normal user: \t#{yellow(@config['user']['email'])}"
    end

    def get_config
      if File.exists?(VCAP_BVT_CONFIG_FILE)
        @multi_target_config = YAML.load_file(VCAP_BVT_CONFIG_FILE)
        raise "Invalid config file format, #{VCAP_BVT_CONFIG_FILE}" unless @multi_target_config.is_a?(Hash)
      else
        @multi_target_config = {}
      end

      # since multi-target information is stored in one config file,
      # so usually get_config method just initiate @config, and @multi_target_config
      # however, once user set environment variable VCAP_BVT_TARGET,
      # get_config method should return specific target information
      if ENV['VCAP_BVT_TARGET'] &&
          @multi_target_config.key?(format_target(ENV['VCAP_BVT_TARGET'])) &&
          $target_config.empty?
        $target_config = @multi_target_config[format_target(ENV['VCAP_BVT_TARGET'])]
      end

      @config = $target_config
      @config
    end

    def save_config(hash = nil)
      @config = hash || @config
      $target_config = Marshal.load(Marshal.dump(@config))

      ## remove password
      @config['user'].delete('passwd') if @config['user']
      @config['admin'].delete('passwd') if @config['admin']

      File.open(VCAP_BVT_CONFIG_FILE, "w") { |f| f.write YAML.dump(@multi_target_config) }
    end

    def get_target
      if ENV['VCAP_BVT_TARGET']
        target = format_target(ENV['VCAP_BVT_TARGET'])
        puts "target read from ENV: \t\t#{yellow(target)}"
      else
        input = ask_and_validate("VCAP Target",
                                 '\A.*',
                                 VCAP_BVT_DEFAULT_TARGET)
        target = format_target(input)
      end
      @multi_target_config[target] = {} unless @multi_target_config.key?(target)
      @config = @multi_target_config[target]
      ENV['VCAP_BVT_TARGET'] = target
      @config['target'] = target
    end

    def get_admin_user
      @config['admin'] = {} if @config['admin'].nil?
      if ENV['VCAP_BVT_ADMIN_USER']
        @config['admin']['email'] = ENV['VCAP_BVT_ADMIN_USER']
        puts "admin user read from ENV: \t#{yellow(@config['admin']['email'])}"
      elsif @config['admin']['email'].nil?
        @config['admin']['email'] = ask_and_validate('Admin User',
                                                     '\A.*\@',
                                                     VCAP_BVT_DEFAULT_ADMIN
                                                    )
      else
        puts "admin user read from #{VCAP_BVT_CONFIG_FILE}: " +
             "\t#{yellow(@config['admin']['email'])}"
      end
    end

    def get_admin_user_passwd
      if ENV['VCAP_BVT_ADMIN_USER_PASSWD']
        @config['admin']['passwd'] = ENV['VCAP_BVT_ADMIN_USER_PASSWD']
      elsif @config['admin']['passwd'].nil?
        @config['admin']['passwd'] = ask_and_validate("Admin User Passwd " +
                                                          "(#{yellow(@config['admin']['email'])})",
                                                      '.*',
                                                      '*',
                                                      '*'
                                                     )
      end
      ENV['VCAP_BVT_ADMIN_USER_PASSWD'] = @config['admin']['passwd']
      @config['admin']['passwd']
    end

    def get_user
      @config['user'] = {} if @config['user'].nil?
      if ENV['VCAP_BVT_USER']
        @config['user']['email'] = ENV['VCAP_BVT_USER']
        puts "normal user read from ENV: \t#{yellow(@config['user']['email'])}"
      elsif @config['user']['email'].nil?
        @config['user']['email'] = ask_and_validate('Non-admin User',
                                                    '\A.*\@',
                                                    VCAP_BVT_DEFAULT_USER
                                                   )
      else
        puts "normal user read from #{VCAP_BVT_CONFIG_FILE}: " +
             "\t#{yellow(@config['user']['email'])}"
      end
    end

    def get_user_passwd
      if ENV['VCAP_BVT_USER_PASSWD']
        @config['user']['passwd'] = ENV['VCAP_BVT_USER_PASSWD']
      elsif @config['user'].nil? || @config['user']['passwd'].nil?
        @config['user']['passwd'] = ask_and_validate("User Passwd " +
                                                         "(#{yellow(@config['user']['email'])})",
                                                     '.*',
                                                     '*',
                                                     '*')
      end
      ENV['VCAP_BVT_USER_PASSWD'] = @config['user']['passwd']
      @config['user']['passwd']
    end

    private

    def ask_and_validate(question, pattern, default = nil, echo = nil)
      res = ask(question, :default => default, :echo => echo)
      while res !~ /#{pattern}/
        puts "Incorrect input"
        res = ask(question, :default => default, :echo => echo)
      end
      res
    end

    def format_target(str)
      if str.start_with? 'http://api.'
        str.gsub('http://api.', '')
      elsif str.start_with? 'api.'
        str.gsub('api.', '')
      else
        str
      end
    end

    def get_script_git_hash
      `git log --pretty=oneline`.split("\n").first
    end

    def cleanup_services_apps(email, passwd)
      session = BVT::Harness::CFSession.new(:email => email,
                                            :passwd => passwd,
                                            :target => @config['target'])
      puts yellow("Ready to clean up for test user: #{session.email}")
      apps = session.apps
      services = session.services

      if services.empty?
        puts "No service has been provisioned by test user: #{session.email}"
      elsif session.email =~ /^t\w{6,7}-\d{1,2}-/ #parallel user, delete without asking
        services.each { |service|
          puts "deleting service: #{service.name}..."
          service.delete
        }
      else
        puts "List all services belong to test user: #{session.email}"
        services.each { |service| puts service.name }
        if ask("Do you want to remove all above servcies?", :default => true)
          services.each { |service| service.delete }
          puts yellow("all services belong to #{session.email} have been removed")
        else
          puts yellow("Keep those services\n")
        end
      end

      if apps.empty?
        puts "No application has been created by test user: #{session.email}"
      elsif session.email =~ /^t\w{6,7}-\d{1,2}-/ #parallel user, delete without asking
        apps.each { |app|
          puts "deleting app: #{app.name}..."
          app.delete
        }
      else
        puts "List all applications belong to test user: #{session.email}"
        apps.each { |app| puts app.name }
        if ask("Do you want to remove all above applications?", :default => true)
          apps.each { |app| app.delete }
          puts yellow("all applications belong to #{session.email} have been removed")
        else
          puts yellow("Keep those applications\n")
        end
      end

      puts yellow("Clean up work for test user: #{session.email} has been done.\n")
    end

    def cleanup_test_accounts
      test_user_template = 'my_fake@email.address'

      session = BVT::Harness::CFSession.new(:admin => true,
                                            :email => @config['admin']['email'],
                                            :passwd => @config['admin']['passwd'],
                                            :target => @config['target'])
      puts yellow("Ready to remove all test users created in admin_user_spec.rb")
      users = session.users.select { |user| user.email =~ /^t.*-#{test_user_template}$/ }

      if users.empty?
        puts "No test user need to be deleted."
      else
        puts "List all test users"
        users.each { |user| puts user.email }
        if ask("Do you want to remove all above users?", :default => true)
          users.each { |user| user.delete }
        else
          puts yellow("Keep those test users\n")
        end
      end
      puts yellow("Clean up test accounts has been done.\n")
    end

    def get_assets_info
      easy = Curl::Easy.new
      easy.url = "#{VCAP_BVT_ASSETS_STORE_URL}/list"
      easy.resolve_mode = :ipv4
      easy.timeout = 10
      begin
        easy.http_get
      rescue Curl::Err::CurlError
        raise RuntimeError,
              red("Cannot connect to yeti assets storage server, #{easy.url}\n" +
                      "Please check your network connection.")
      end

      if easy.response_code == HTTP_RESPONSE_CODE::OK
        parser = Yajl::Parser.new
        return parser.parse(easy.body_str)
      end
    end

    def check_md5(filepath)
      Digest::MD5.hexdigest(File.read(filepath))
    end

    def download_binary(filepath)
      filename = File.basename(filepath)
      easy = Curl::Easy.new
      easy.url = "#{VCAP_BVT_ASSETS_STORE_URL}/files/#{filename}"
      easy.resolve_mode = :ipv4
      easy.timeout = 60 * 5
      begin
        easy.http_get
        # retry once
        unless easy.response_code == HTTP_RESPONSE_CODE::OK
          sleep(1) # waiting for 1 second and try again
          easy.http_get
        end
      rescue
        raise RuntimeError,
              red("Download faild, might be caused by unstable network.\n" +
                      "Please try again.")
      end

      if easy.response_code == HTTP_RESPONSE_CODE::OK
        contents = easy.body_str.chomp
        File.open(filepath, 'wb') { |f| f.write(contents) }
      else
        raise RuntimeError, "Fail to download binary #{filename}"
      end
    end

    extend self
  end
end
