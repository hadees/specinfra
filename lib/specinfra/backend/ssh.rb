require 'specinfra/backend/exec'
require 'net/ssh'

module Specinfra
  module Backend
    class Ssh < Exec
      def prompt
        'Password: '
      end

      def run_command(cmd, opt={})
        cmd = build_command(cmd)
        cmd = add_pre_command(cmd)
        ret = ssh_exec!(cmd)

        ret[:stdout].gsub!(/\r\n/, "\n")

        if @example
          @example.metadata[:command] = cmd
          @example.metadata[:stdout]  = ret[:stdout]
        end

        CommandResult.new ret
      end

      def build_command(cmd)
        cmd = super(cmd)
        user = Specinfra.configuration.ssh_options[:user]
        disable_sudo = Specinfra.configuration.disable_sudo
        if user != 'root' && !disable_sudo
          cmd = "#{sudo} -p '#{prompt}' #{cmd}"
        end
        cmd
      end

      def copy_file(from, to)
        scp = Specinfra.configuration.scp
        begin
          scp.upload!(from, to)
        rescue => e
          return false
        end
        true
      end

      private
      def ssh_exec!(command)
        stdout_data = ''
        stderr_data = ''
        exit_status = nil
        exit_signal = nil

        if Specinfra.configuration.ssh.nil?
          Specinfra.configuration.ssh = Net::SSH.start(
            Specinfra.configuration.host,
            Specinfra.configuration.ssh_options[:user],
            Specinfra.configuration.ssh_options
          )
        end

        ssh = Specinfra.configuration.ssh
        ssh.open_channel do |channel|
          if Specinfra.configuration.sudo_password or Specinfra.configuration.request_pty
            channel.request_pty do |ch, success|
              abort "Could not obtain pty " if !success
            end
          end
          channel.exec("#{command}") do |ch, success|
            abort "FAILED: couldn't execute command (ssh.channel.exec)" if !success
            channel.on_data do |ch, data|
              if data.match /^#{prompt}/
                channel.send_data "#{Specinfra.configuration.sudo_password}\n"
              else
                stdout_data += data
              end
            end

            channel.on_extended_data do |ch, type, data|
              if data.match /you must have a tty to run sudo/
                abort 'Please set "Specinfra.configuration.request_pty = true" or "c.request_pty = true" in your spec_helper.rb or other appropriate file.'
              end

              if data.match /^sudo: no tty present and no askpass program specified/
                abort "Please set sudo password by using SUDO_PASSWORD or ASK_SUDO_PASSWORD environment variable"
              else
                stderr_data += data
              end
            end

            channel.on_request("exit-status") do |ch, data|
              exit_status = data.read_long
            end

            channel.on_request("exit-signal") do |ch, data|
              exit_signal = data.read_long
            end
          end
        end
        ssh.loop
        { :stdout => stdout_data, :stderr => stderr_data, :exit_status => exit_status, :exit_signal => exit_signal }
      end

      def sudo
        if sudo_path = Specinfra.configuration.sudo_path
          sudo_path += '/sudo'
        else
          sudo_path = 'sudo'
        end

        sudo_options = Specinfra.configuration.sudo_options
        if sudo_options
          sudo_options = sudo_options.shelljoin if sudo_options.is_a?(Array)
          sudo_options = ' ' + sudo_options
        end

        "#{sudo_path.shellescape}#{sudo_options}"
      end
    end
  end
end
