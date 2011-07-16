=begin
                  Arachni
  Copyright (c) 2010-2011 Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>

  This is free software; you can copy and distribute and modify
  this program under the term of the GPL v2.0 License
  (See LICENSE file for details)

=end

require 'datamapper'
require 'net/ssh'

module Arachni
module UI
module Web
module Addons

class AutoDeploy

#
#
# @author: Tasos "Zapotek" Laskos
#                                      <tasos.laskos@gmail.com>
#                                      <zapotek@segfault.gr>
# @version: 0.1
#
class Manager

    include Utilities

    ARCHIVE_PATH = 'http://172.16.51.1/~zapotek/'
    ARCHIVE_NAME = 'arachni-v0.3-autodeploy'
    ARCHIVE_EXT  = '.tar.gz'

    EXEC = 'arachni_xmlrpcd'

    class Deployment
        include DataMapper::Resource

        property :id,           Serial
        property :host,         String
        property :port,         String
        property :user,         String
        property :created_at,   DateTime, :default => Time.now
    end

    #
    # Initializes the Scheduler and starts the clock.
    #
    #
    def initialize( opts, settings )
        @opts     = opts
        @settings = settings

        DataMapper::setup( :default, "sqlite3://#{@settings.db}/default.db" )
        DataMapper.finalize

        Deployment.auto_upgrade!
    end

    def setup( deployment, password )

        begin
            session = ssh( deployment.host, deployment.user, password )
        rescue Exception => e
            return {
                :out => e.to_s + "\n" + e.backtrace.join( "\n" ),
                :code => 1
             }
         end

        Thread.new {

            @@setup ||= {}
            url = get_url( deployment )
            @@setup[url] ||= {}

            @@setup[url][:deployment] ||= deployment
            @@setup[url][:status] = 'working'

            wget = 'wget --output-document=' + ARCHIVE_NAME + '-' + deployment.port +
                ARCHIVE_EXT + ' ' + ARCHIVE_PATH + ARCHIVE_NAME + ARCHIVE_EXT
            ret = ssh_exec!( deployment, session, wget )

            if ret[:code] != 0
                @@setup[url][:status] = 'failed'
                return
            end

            mkdir = 'mkdir ' + ARCHIVE_NAME + '-' + deployment.port
            ret = ssh_exec!( deployment, session,  mkdir )

            if ret[:code] != 0
                @@setup[url][:status] = 'failed'
                return
            end


            tar = 'tar xvf ' + ARCHIVE_NAME + '-' + deployment.port + ARCHIVE_EXT +
                ' -C ' + ARCHIVE_NAME + '-' + deployment.port
            ret = ssh_exec!( deployment, session,  tar )

            if ret[:code] != 0
                @@setup[url][:status] = 'failed'
                return
            end


            chmod = 'chmod +x ' + ARCHIVE_NAME + '-' + deployment.port + '/' +
                ARCHIVE_NAME + '/' + EXEC
            ret = ssh_exec!( deployment, session, chmod )

            if ret[:code] != 0
                @@setup[url][:status] = 'failed'
                return
            end

            @@setup[url][:status] = 'finished'
        }

        return get_url( deployment )
    end

    def output( channel )
        return @@setup[channel]
    end

    def finalize_setup( channel )
        @@setup[channel][:deployment].save
        return @@setup[channel][:deployment]
    end

    def uninstall( deployment, password )

        begin
            session = ssh( deployment.host, deployment.user, password )
        rescue Exception => e
            return {
                :out => e.to_s + "\n" + e.backtrace.join( "\n" ),
                :code => 1
             }
         end

        out = "\n" + rm = "rm -rf #{ARCHIVE_NAME}-#{deployment.port}*"
        ret = ssh_exec!( deployment, session, rm )
        out += "\n" + ret[:stdout] + "\n" + ret[:stderr]

        return { :out => out, :code => ret[:code] } if ret[:code] != 0

        return { :out => out }
    end

    def run( deployment, password )
        session = ssh( deployment.host, deployment.user, password )
        session.exec!( 'nohup ./' + ARCHIVE_NAME + '-' + deployment.port + '/' +
                ARCHIVE_NAME + '/' + EXEC + ' --port=' + deployment.port +
            ' > arachni-xmlrpcd-startup.log 2>&1 &' )

        sleep( 5 )
    end


    def list
        Deployment.all.reverse
    end

    def get( id )
        Deployment.get( id )
    end

    def delete( id, password )
        deployment = get( id )
        ret = uninstall( deployment, password )
        deployment.destroy
        return ret
    end

    def ssh( host, user, password )
        @@ssh ||= {}
        @@ssh[user + '@' + host] ||= Net::SSH.start( host, user, :password => password )
    end

    def get_url( deployment )
        deployment.user + '@' + deployment.host + ':' + deployment.port
    end

    def ssh_exec!( deployment, ssh, command )

        stdout_data = ""
        stderr_data = ""

        exit_code   = nil
        exit_signal = nil

        @@setup ||= {}

        url = get_url( deployment )

        @@setup[url] ||= {}
        @@setup[url][:code]   = 0
        @@setup[url][:output] ||= ''
        @@setup[url][:output] += "\n" + command + "\n"

        ssh.open_channel do |channel|
            channel.exec(command) do |ch, success|
                unless success
                    abort "FAILED: couldn't execute command (ssh.channel.exec)"
                end

                channel.on_data {
                    |ch, data|
                    stdout_data += data
                    @@setup[url][:output] += data
                }

                channel.on_extended_data {
                    |ch, type, data|
                    stderr_data += data
                    @@setup[url][:output] += data
                }

                channel.on_request( "exit-status" ) {
                    |ch, data|
                    exit_code = data.read_long
                    @@setup[url][:code] = data.read_long
                }

                channel.on_request( "exit-signal" ) {
                    |ch, data|
                    exit_signal = data.read_long
                }

            end
        end

        ssh.loop
        return {
            :stdout => stdout_data,
            :stderr => stderr_data,
            :code   => exit_code,
            :signal => exit_signal
        }
    end

end
end
end
end
end
end
