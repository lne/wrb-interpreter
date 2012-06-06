require 'bundler/setup'
require 'sinatra'
require 'timeout'

#-------------------------------
# settings
#-------------------------------

AVAILABLE_RUBY_VERSIONS = ['1.8.6', '1.8.7', '1.9.1', '1.9.2', '1.9.3']

configure :production do
  set :logging, Logger::DEBUG
end


#-------------------------------
# routes
#-------------------------------

post '/interpret' do
  interpret
end

not_found do
  ['404', '']
end


#-------------------------------
# filters
#-------------------------------

before '/interpret' do
  logger.info "%s %s %s - %s" % [
    env["REQUEST_METHOD"],
    env["PATH_INFO"],
    env["QUERY_STRING"].empty? ? "" : "?" + env["QUERY_STRING"],
    env['HTTP_X_FORWARDED_FOR'] || env["REMOTE_ADDR"] || "?.?.?.?"
   ]
end

# parse params
before '/interpret' do
  logger.info params.inspect
  @version = params['v'] || params['version']
  @code    = params['c'] || params['s'] || params['code'] || params['script']
  if @version.nil?
    halt 403, "<ArgumentError> version of ruby is not given."
  end
  unless AVAILABLE_RUBY_VERSIONS.include?(@version)
    halt 403, "<ArgumentError> ruby #@version is not available."
  end
  if @code.nil?
    halt 200, ""
  end
end


#-------------------------------
# logics
#-------------------------------

def interpret
  @wrb = WRB.new(logger)
  @wrb.exec(@code, @version, params)
end

class WRB
  class WRBSystemException < StandardError; end
  class TimeoutError  < WRBSystemException; end
  class ResourceError < WRBSystemException; end
  class UnknownError  < WRBSystemException; end

  JAIL_ROOT = "/jail/readonly"
  JAIL_TEMP = "#{JAIL_ROOT}/tmp"
  UID = GID = 500
  CAGE = '/usr/sbin/cage'
  FORK_ERROR = 'Resource temporarily unavailable - fork(2) (Errno::EAGAIN)'

  TIMEOUT = 5         # Second
  MAXSIZE = 10*1024   # Byte
  PROCESS_LIMITATION = 50*1024*1024 #Byte

  attr :logger

  def initialize(logger)
    @logger = logger
  end

  def exec(code, version, opts = {})
    filename = opts[:name] || 'line'
    std = err = ""
    std_r, std_w = IO.pipe
    err_r, err_w = IO.pipe
    tmpname = process_tempfile(code) do |tmpfilename|
      exec_with_restriction(tmpfilename, version, std_w, err_w)
    end
    std_w.close
    err_w.close
    res = timeout(TIMEOUT) do
      std = std_r.read(MAXSIZE)
      err = err_r.read(MAXSIZE)
      "#{std}#{err}"
    end
    raise WRB::ResourceError.new("Resource is unavailable.") if res.include?(FORK_ERROR)
    raise WRB::ResourceError.new("result data is over than #{MAXSIZE} byte.") if res.size >= MAXSIZE
    logger.debug "result: #{res}"
    res.gsub(/\/tmp\/#{tmpname}/, filename)
  rescue Exception
    wrb_error = handle_error($!)
    "#{wrb_error}"
  ensure
    kill_unfinished_process(tmpname)
    std_w.close unless std_w.closed?
    err_w.close unless err_w.closed?
    std_r.close unless std_r.closed?
    err_r.close unless err_r.closed?
    logger.debug "exec finished."
  end

  def kill_unfinished_process(keyword)
    count = `pgrep -f 'weiaaa'`.split("\n").size
    if count > 0
      logger.info `ps ux`
      logger.info "pkill -9 -f '#{keyword}'"
      `pkill -9 -f #{jkeyword}`
      logger.info `ps ux`
    end
  end

  def handle_error(e)
    logger.info "<#{e.class}> #{e.message}"
    logger.info e.backtrace[0..5].join("\n")
    case e
    when WRBSystemException
      # nothing
    when Timeout::Error
      e = WRB::TimeoutError.new(e.message)
    else
      e = WRB::UnknownError.new('fatal error occurred.')
      logger.error "unknown error occurred."
    end
    "<#{e.class}> #{e.message}"
  end

  def process_tempfile(data, name = '')
    file = Tempfile.new(name.to_s, JAIL_TEMP)
    logger.debug "create tempfile => #{file.path}"
    file.puts data
    file.close
    logger.debug `ls -l #{JAIL_TEMP}`
    yield(File.basename(file.path)) if block_given?
    File.basename(file.path)
  ensure
    file.close! if file # close and delete tempfile
  end

  def exec_with_restriction(name, ver, out, err)
    ruby     = '/bin/ruby'
    filepath = File.join('/tmp', name)
    cmd      = "sudo #{CAGE} -u #{UID} -g #{GID} -- #{JAIL_ROOT} #{ruby} #{ver} #{filepath}"
    env      = { "PATH"=>"/usr/bin:/bin" }
    options  = { :chdir => '/', :out => out, :err => err, :unsetenv_others => true }
    options[:rlimit_core]   = [0, PROCESS_LIMITATION]
    options[:rlimit_cpu]    = 5                   # second
    options[:rlimit_nofile] = 100                 # count
    options[:rlimit_nproc]  = 100                 # count
    options[:rlimit_data]   = PROCESS_LIMITATION  # byte
    options[:rlimit_fsize]  = PROCESS_LIMITATION  # byte
    options[:rlimit_stack]  = PROCESS_LIMITATION  # byte
    options[:rlimit_as]     = PROCESS_LIMITATION  # byte 
    options[:rlimit_rss]    = PROCESS_LIMITATION  # byte
    logger.info "spawn #{cmd.inspect}"
    timeout(TIMEOUT) do
      spawn(env, cmd, options)
      Process.waitall
    end
    logger.info "spawn finished."
  end
end
