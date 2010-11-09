##
# $Id$
##

##
# This file is part of the Metasploit Framework and may be subject to
# redistribution and commercial restrictions. Please see the Metasploit
# Framework web site for more information on licensing and terms of use.
# http://metasploit.com/framework/
##

require 'msf/core'

class Metasploit3 < Msf::Auxiliary

	include Msf::Auxiliary::Report
	include Msf::Exploit::Remote::Udp

	def initialize
		super(
			'Name'        => 'SSDP M-SEARCH Gateway Information Discovery',
			'Version'     => '$Revision$',
			'Description' => 'Discover information about the local gateway via UPnP',
			'Author'      => 'todb',
			'License'     => MSF_LICENSE
		)

		register_options(
			[
				Opt::CHOST,
				Opt::RPORT(1900),
				Opt::RHOST("239.255.255.250"), # Generally don't change this.
				OptPort.new('SRVPORT', [ false, "The source port to listen for replies.", 0]),
			], self.class
		)

		@result = []
	end

	def upnp_client_listener()
		sock = Rex::Socket::Udp.create(
			'LocalHost' => datastore['CHOST'] || nil,
			'LocalPort' => @sport,
			'Context' => {'Msf' => framework, 'MsfExploit' => self}
		)
		add_socket(sock)
		while (r = sock.recvfrom(65535, 5) and r[1])
			@result << r
		end
	end

	def set_server_port
		if datastore['SRVPORT'].to_i.zero?
			datastore['SRVPORT'] = rand(10_000) + 40_000
		else
			datastore['SRVPORT'].to_i
		end
	end

	def rport
		datastore['RPORT'].to_i
	end

	def rhost
		datastore['RHOST']
	end

	def target
		"%s:%d" % [rhost, rport]
	end

	# The problem is, the response comes from someplace we're not
	# expecting, since we're sending out on the multicast address.
	# This means we need to listen on our sending port, either with
	# packet craftiness or by being able to set our sport.
	def run

		print_status("#{target}: Sending SSDP M-SEARCH Probe.")
		@result = []

		@sport = set_server_port

		begin
			udp_send_sock = nil

			server_thread = Thread.new { upnp_client_listener }

			# TODO: Test to see if this scheme will work when pivoted.
			
			# Create an unbound UDP socket if no CHOST is specified, otherwise
			# create a UDP socket bound to CHOST (in order to avail of pivoting)
			udp_send_sock = Rex::Socket::Udp.create(
				'LocalHost' => datastore['CHOST'] || nil,
				'LocalPort' => @sport,
				'Context' => {'Msf' => framework, 'MsfExploit' => self}
			)
			add_socket(udp_send_sock)
			data = create_msearch_packet(rhost,rport)
			begin
				udp_send_sock.sendto(data, rhost, rport, 0)
			rescue ::Interrupt
				raise $!
			rescue ::Rex::HostUnreachable, ::Rex::ConnectionTimeout, ::Rex::ConnectionRefused
				nil
			end

			begin
				Timeout.timeout(6) do
					while @result.size.zero?
						select(nil, nil, nil, 1.9)
						parse_reply @result
					end
				end
			rescue Timeout::Error
			end
		end
	end

	# Someday, take all these very similiar parse_reply functions
	# and make them proper block consumers.
	def parse_reply(pkts)
		pkts.each do |pkt|
			# Ignore "empty" packets
			return if not pkt[1]

			addr = pkt[1]
			if(addr =~ /^::ffff:/)
				addr = addr.sub(/^::ffff:/, '')
			end

			port = pkt[2]

			data = pkt[0]
			info = []
			if data[/Server:[\s]*(.*)/]
				info << "\"#{$1.strip}\""
			end

			if data[/Location:[\s]*(.*)/] || 
				info << $1.strip
			end

			if data[/USN:[\s]*(.*)/]
				info << $1.strip
			end

			report_service(
				:host  => addr,
				:port  => port,
				:proto => 'udp',
				:name  => 'SSDP',
				:info  => info.join("|")
			)
			print_good "#{addr}:#{port}: Got an SSDP response from #{info.first}"
		end
	end

	# I'm sure this could be a million times cooler.
	def create_msearch_packet(host,port)
		data = "M-SEARCH * HTTP/1.1\r\n"
		data << "Host:#{host}:#{port}\r\n"
		data << "ST:urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n"
		data << "Man:\"ssdp:discover\"\r\n"
		data << "MX:3\r\n"
		return data
	end

end
