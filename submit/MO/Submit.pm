# A Perl module for communicating with the MO Submit Server
# (c) 2007 Martin Mares <mj@ucw.cz>

package MO::Submit;

use strict;
use warnings;

use IO::Socket::INET;
use IO::Socket::SSL; # qw(debug3);
use Sherlock::Object;

sub new($) {
	my $self = {
		"Server" => "localhost:8888",
		"Key" => "client-key.pem",
		"Cert" => "client-cert.pem",
		"CACert" => "ca-cert.pem",
		"Trace" => 0,
		"user" => "testuser",
		"sk" => undef,
		"error" => undef,
	};
	# FIXME: Read config file
	return bless $self;
}

sub DESTROY($) {
	my $self = shift @_;
	$self->disconnect;
}

sub log($$) {
	my ($self, $msg) = @_;
	print STDERR "LOG: $msg\n" if $self->{"Trace"};
}

sub err($$) {
	my ($self, $msg) = @_;
	print STDERR "ERROR: $msg\n" if $self->{"Trace"};
	$self->{"error"} = $msg;
	$self->disconnect;
}

sub is_connected($) {
	my $self = shift @_;
	return defined $self->{"sk"};
}

sub disconnect($) {
	my $self = shift @_;
	if ($self->is_connected) {
		close $self->{"sk"};
		$self->{"sk"} = undef;
		$self->log("Disconnected");
	}
}

sub connect($) {
	my $self = shift @_;
	$self->disconnect;
	$self->log("Connecting to submit server");
	my $sk = new IO::Socket::INET(
		PeerAddr => $self->{"Server"},
		Proto => "tcp",
	);
	if (!defined $sk) {
		$self->err("Cannot connect to server: $!");
		return undef;
	}
	my $z = <$sk>;
	if (!defined $z) {
		$self->err("Server failed to send a welcome message");
		close $sk;
		return undef;
	}
	chomp $z;
	if ($z !~ /^\+/) {
		$self->err("Server rejected the connection: $z");
		close $sk;
		return undef;
	}
	if ($z =~ /TLS/) {
		$self->log("Starting TLS");
		$sk = IO::Socket::SSL->start_SSL(
			$sk,
			SSL_version => 'TLSv1',
			SSL_use_cert => 1,
			SSL_key_file => "client-key.pem",
			SSL_cert_file => "client-cert.pem",
			SSL_ca_file => "ca-cert.pem",
			SSL_verify_mode => 3,
		);
		if (!defined $sk) {
			$self->err("Cannot establish TLS connection: " . IO::Socket::SSL::errstr());
			return undef;
		}
	}
	$self->{"sk"} = $sk;

	$self->log("Logging in");
	my $req = new Sherlock::Object("U" => $self->{"user"});
	my $reply = $self->request($req);
	my $err = $reply->get("-");
	if (defined $err) {
		$self->err("Cannot log in: $err");
		return undef;
	}

	$self->log("Connected");
	return 1;
}

sub request($$) {
	my ($self, $obj) = @_;
	my $sk = $self->{"sk"};
	$obj->write($sk);	### FIXME: Flushing
	if ($sk->error) {
		$self->err("Connection broken");
		return undef;
	}
	print $sk "\n";
	return $self->reply;
}

sub reply($) {
	my ($self, $obj) = @_;
	my $sk = $self->{"sk"};
	my $reply = new Sherlock::Object;
	if ($reply->read($sk)) {
		return $reply;
	} else {
		$self->err("Connection broken");
		return undef;
	}
}

sub send_file($$$) {
	my ($self, $fh, $size) = @_;
	my $sk = $self->{"sk"};
	while ($size) {
		my $l = ($size < 4096 ? $size : 4096);
		my $buf = "";
		if ($fh->read($buf, $l) != $l) {
			$self->err("File shrunk during upload");
			return undef;
		}
		$sk->write($buf, $l);
		if ($sk->error) {
			$self->err("Connection broken");
			return undef;
		}
		$size -= $l;
	}
	return $self->reply;
}

1;