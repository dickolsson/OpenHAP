# NOTE: Production deployments should use deps/*.txt with 'make deps'
# This file is maintained for development convenience and carton compatibility

# Crypto dependencies required for HAP protocol
requires 'Crypt::Ed25519';
requires 'Crypt::Curve25519';
requires 'CryptX';

# JSON parsing
requires 'JSON::XS';

# GMP backend for Math::BigInt: SRP does 3072-bit modular exponentiation,
# which is impractically slow in the pure-Perl backend. Math::BigInt loads
# this automatically when present.
requires 'Math::BigInt::GMP';

# MQTT client for device integration
requires 'Net::MQTT::Simple';

# Test dependencies for testing and CI
on 'test' => sub {
	requires 'Perl::Critic';
	requires 'Perl::Tidy';
};

# Development dependencies for OpenHVF
on 'develop' => sub {
	requires 'HTTP::Daemon';
	requires 'LWP::UserAgent';
	requires 'Net::SSH2';
};
