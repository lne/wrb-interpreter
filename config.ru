$: << File.dirname(__FILE__)
require 'logger'

log = File.new("log/interpreter.log", "a+")
log.sync = true
STDOUT.reopen(log)
STDERR.reopen(log)

require 'interpreter'
run Sinatra::Application
