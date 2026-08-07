# NOTE: For production deployments, use deps/*.txt with 'make deps'.
# This file exists for development convenience and carton compatibility.

# Crypto dependencies for the HAP protocol
requires 'Crypt::Ed25519';
requires 'Crypt::Curve25519';
requires 'CryptX';

# JSON parsing
requires 'JSON::XS';

# GMP backend for Math::BigInt. SRP does 3072-bit modular exponentiation.
# That operation is impractically slow in the pure-Perl backend.
# Math::BigInt loads this backend automatically when present.
requires 'Math::BigInt::GMP';

# MQTT client for device integration
requires 'Net::MQTT::Simple';

# Test dependencies for testing and CI
on 'test' => sub {
	requires 'Perl::Critic';
	requires 'Perl::Tidy';
};

# Development dependencies for FuguVM. Fugu::Proxy uses HTTP::Request
# and HTTP::Response, which the HTTP::Message distribution provides,
# and URI.
on 'develop' => sub {
	requires 'HTTP::Daemon';
	requires 'HTTP::Message';
	requires 'LWP::UserAgent';
	requires 'Net::SSH2';
	requires 'URI';
};
