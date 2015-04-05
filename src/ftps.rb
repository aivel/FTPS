require 'eventmachine'

=begin
  Implements an FTP server(passive mode).
  The list of commands available:

    * USER <NAME>
    * PASS <PASSWORD>
    * PASV - enter the passive FTP-mode
    * RNFR <FILENAME> - select a file on the server to be renamed
    * RNTO <FILENAME> - rename the file, selected with RNFR command, to <FILENAME>
    * STOR <FILENAME> - save file on the server with name <FILENAME>
    * FNRC - file is sent
    * RETR <FILENAME> - send file, named <FILENAME>, to the client
    * DELE <FILENAME> - delete file, named <FILENAME>, from the server
    * LIST - get contents of the current folder
    * PWD - get current directory path
    * QUIT - close the connection
    * NOOP - does nothing
=end

module DataConnectionServer
  def initialize(options)
    @address = options[:address]
    @post = options[:port]
    @parent = options[:parent]
    @filepath = nil
    @pending_file = nil

    send_message_to_parent({:remember_me => self})
  end

  def send_message_to_parent(message)
    @parent.send(:on_message, message)
  end

  def post_init
    @mode = :binary
  end

  def receive_data data
    if @filepath == nil
      return
    end

    unless File.exist? @filepath
      unless @pending_file.nil?
        @pending_file = nil
      end

      @pending_file = File.open(@filepath, 'wb')
    end

    @pending_file.write(data)
  end

  def on_message(message)
    puts(message)

    case
      when !message[:send_file].nil?
        send_message_to_parent({:is_busy => true})
        send_file(message[:filepath])
        send_message_to_parent({:is_busy => false})
      when !message[:receive_file].nil?
        send_message_to_parent({:is_busy => true})
        @filepath = message[:filepath]
      when !message[:file_is_received].nil?
        unless @pending_file.nil?
          send_message_to_parent({:is_busy => false})
          @pending_file.flush
          @pending_file.close
          @filepath = nil
          @pending_file = nil
        end
      else
        # type code here
    end
  end

  def send_file(filepath)
    puts("I'm going to send a file: #{filepath}")

    content = File.binread(filepath)
    send_data content
  end

  def unbind
    SERVER_AVAILABLE_DATA_PORTS << @port
  end
end

module ControlConnectionServer
  LBRK = "\r\n"
  USERNAME, PASSWORD = 'TEST', 'TEST'
  FTP_DIR_NAME = 'public_ftp'
  PWD = File.join(File.dirname(__FILE__), FTP_DIR_NAME)
  COMMAND_SUCCEED, COMMAND_FAILED, COMMAND_CONNECTION_CLOSED = '240', '140', '520'
  PROHIBITED_FILENAME_SYMBOLS = ['\\', '/']

  def post_init
    @mode = :binary
    @file_to_rename = nil
    @data_connection_thread = nil
    @child = nil
    @child_is_busy = nil
    @username_present = false
    @is_logged = false

    puts '-- someone connected to the server!'

    if Dir.exist? FTP_DIR_NAME or Dir.mkdir FTP_DIR_NAME
      puts 'OK, directory is present now: ' + PWD
      send_response '220 Hi th3re\r\n' # welcome
    else
      puts 'Failed to create directory ' + PWD
      send_response '421' # closing connection
      close_connection
    end
  end

  def send_response(msg, no_linebreak = false)
    msg = '' if msg == nil
    msg += LBRK unless no_linebreak
    send_data msg
  end

  def receive_data data
    response =
      case data
        when /^USER/
          user = data[5..-1].chomp
          user == USERNAME ? COMMAND_SUCCEED : COMMAND_FAILED
        when /^PASS/
          pass = data[5..-1].chomp
          pass == PASSWORD ? COMMAND_SUCCEED : COMMAND_FAILED
        when /^PWD/
          "#{COMMAND_SUCCEED} \"%s\"" % PWD
        when /^DELE/
          result, filepath = validate_filename(data[5..-1].chomp)

          if !File.exist? filepath or !File.delete(filepath)
            result = COMMAND_FAILED
          end

          result
        when /^QUIT/
          COMMAND_CONNECTION_CLOSED
        when /^PASV/
          if SERVER_AVAILABLE_DATA_PORTS.empty?
            COMMAND_FAILED
          else
            @data_port = SERVER_AVAILABLE_DATA_PORTS.shift
            options = {:address => SERVER_ADDRESS, :port => @data_port,
                       :parent => self}
            puts(@on_message.nil?)

            @data_connection_thread = Thread.new do
              EventMachine.run {
                EventMachine.start_server SERVER_ADDRESS, @data_port, DataConnectionServer, options
              }
            end

            "#{COMMAND_SUCCEED} #{SERVER_ADDRESS}:#{@data_port}"
          end
        when /^LIST/
          entities = []

          Dir.entries(PWD).select do |e|
            entities.push(((File.directory? e)? 'd:' : 'f:') + e.to_s)
          end

          result = "#{COMMAND_SUCCEED}#{LBRK}"

          entities.each_with_index do |e, i|
            result << e.to_s
            result << ((i == entities.size - 1) ? '' : LBRK)
          end

          result
        when /^NOOP/
          COMMAND_SUCCEED
        when /^RETR/
          result, filepath = validate_filename(data[5..-1].chomp)

          unless File.exist? filepath or @child_is_busy == false or !@child.nil?
            result = COMMAND_FAILED
          end

          if result == COMMAND_SUCCEED
            send_message_to_child({:send_file => true,
                                   :filepath => filepath})
          end

          result
        when /^STOR/
          result, filepath = validate_filename(data[5..-1].chomp)

          if File.exist? filepath or @child_is_busy == true or @child.nil?
            result = COMMAND_FAILED
          end

          if result == COMMAND_SUCCEED
            send_message_to_child({:receive_file => true,
                                   :filepath => filepath})
          end

          result
        when /^FNRC/
          send_message_to_child({:file_is_received => true})
        when /^ABOR/
          @data_connection_thread
        when /^RNFR/
          result, filepath = validate_filename(data[5..-1].chomp)

          unless File.exist? filepath
            result = COMMAND_FAILED
          end

          if result == COMMAND_SUCCEED
            @file_to_rename = filepath
          end

          result
        when /^RNTO/
          result, filepath = validate_filename(data[5..-1].chomp)

          if @file_to_rename == nil or !File.exist? @file_to_rename
            result = COMMAND_FAILED
          end

          if result == COMMAND_SUCCEED
            if !File.exist? filepath and File.rename(@file_to_rename, filepath)
              @file_to_rename = nil
            else
              result = COMMAND_FAILED
            end
          end

          result
        else
          # type code here
      end

    puts "#{data.chomp}: #{response}"

    send_response response

    if response == COMMAND_CONNECTION_CLOSED
      close_connection
    end
  end

  def validate_filename(filename)
    result = COMMAND_SUCCEED

    PROHIBITED_FILENAME_SYMBOLS.each do |char|
      if filename.to_s.include? char
        result = COMMAND_FAILED
        break
      end
    end

    filepath = File.join(PWD, filename)
    return result, filepath
  end

  def on_message(message)
    case
      when !message[:remember_me].nil?
        @child = message[:remember_me]
      when !message[:forget_me].nil?
        @child = nil
      when !message[:is_busy].nil?
        @child_is_busy = message[:is_busy]
      else
        puts("parent > on_message({#{message}}) failed")
    end
  end

  def send_message_to_child(message)
    if @child.nil?
      return
    end

    @child.send(:on_message, message)
  end

  def unbind
    puts '-- someone disconnected from the server!'
  end
end

SERVER_ADDRESS = '127.0.0.1'
SERVER_PORT = 8800
SERVER_AVAILABLE_DATA_PORTS =*(8801..8810)

# Note that this will block current thread.
EventMachine.run {
  EventMachine.start_server SERVER_ADDRESS, 8800, ControlConnectionServer
}