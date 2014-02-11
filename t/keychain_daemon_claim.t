#!/usr/bin/env perl

use strict;
use warnings;

use Nessy::Keychain::Daemon::Claim;

use JSON;
use Carp;
use Data::Dumper;
use Test::More tests => 118;

# defaults when creating a new claim object for testing
our $url = 'http://example.org';
our $resource_name = 'foo';
our $ttl = 1;

test_failed_constructor();
test_constructor();
test_start_state_machine();

test_registration_response_201();
test_registration_response_202();
test_registration_response_400();

test_send_activating();
test_activating_response_409();
test_activating_response_200();
test_activating_response_400();

test_send_renewal();
test_renewal_response_200();
test_renewal_response_400();

test_send_release();
test_release_response_204();
test_release_response_400();
test_release_response_409();

sub _new_claim_and_keychain {
    my $keychain = Nessy::Keychain::Daemon::Fake->new();
    my $claim = Nessy::Keychain::Daemon::TestClaim->new(
                url => $url,
                resource_name => $resource_name,
                keychain => $keychain,
                ttl => $ttl,
            );
    return ($claim, $keychain);
}

sub test_failed_constructor {

    my $claim;

    $claim = eval { Nessy::Keychain::Daemon::Claim->new() };
    ok($@, 'Calling new() without args throws an exception');

    my %all_params = (
            url => 'http://test.org',
            resource_name => 'foo',
            keychain => \'bar',
            ttl => 1,
        );
    foreach my $missing_arg ( keys %all_params ) {
        my %args = %all_params;
        delete $args{$missing_arg};

        $claim = eval { Nessy::Keychain::Daemon::Claim->new( %args ) };
        like($@,
            qr($missing_arg is a required param),
            "missing arg $missing_arg throws an exception");
    }
}

sub test_constructor {
    my $claim;
    my $keychain = Nessy::Keychain::Daemon::Fake->new();
    $claim = Nessy::Keychain::Daemon::TestClaim->new(
                url => $url,
                resource_name => $resource_name,
                keychain => $keychain,
                ttl => $ttl,
            );
    ok($claim, 'Create Claim');
}

sub _verify_http_params {
    my $got = shift;
    my @expected = @_;

    is(scalar(@$got), scalar(@expected), 'got '.scalar(@expected).' http request params');
    for (my $i = 0; $i < @expected; $i++) {
        my $code = pop @{$got->[$i]};
        is_deeply($got->[$i], $expected[$i], "http request param $i");
        is(ref($code), 'CODE', "callback for param $i");
    }
}

sub test_start_state_machine {

    my ($claim, $keychain) = _new_claim_and_keychain();
    ok($claim, 'Create new Claim');
    is($claim->state, 'new', 'Newly created Claim is in state new');

    $claim->expected_state_transitions('registering');
    ok($claim->start(),'start()');
    is(scalar($claim->remaining_state_transitions), 0, 'expected state transitions for start()');

    my $params = $claim->_http_method_params();
    my $json = JSON->new();
    _verify_http_params($params,
        [ 'POST' => "${url}/claims",
          $json->encode({ resource => $resource_name }),
          'Content-Type' => 'application/json',
        ]);

    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');
    ok(! $keychain->claim_failed, 'Keychain was not notified about failure');
}

sub test_registration_response_201 {
    my ($claim, $keychain) = _new_claim_and_keychain();
    ok($claim, 'Create new Claim');

    $claim->state('registering');
    my $claim_location_url = "${url}/claim/123";

    my $response_handler = $claim->_make_response_generator('claim', 'recv_register_response');
    ok( $response_handler->('', { Status => 201, Location => $claim_location_url}),
        'send 201 response to registration');
    is($claim->state(), 'active', 'Claim state is active');
    ok($claim->timer_watcher, 'Claim created a timer');
    is($keychain->claim_succeeded, $resource_name, 'Keychain was notified about success');
    ok(! $keychain->claim_failed, 'Keychain was not notified about failure');
    is($claim->claim_location_url, $claim_location_url, 'Claim location URL');
}

sub test_registration_response_202 {
    my ($claim, $keychain) = _new_claim_and_keychain();

    $claim->state('registering');
    my $claim_location_url = "${url}/claim/123";

    my $response_handler = $claim->_make_response_generator('claim', 'recv_register_response');
    ok( $response_handler->('', { Status => 202, Location => $claim_location_url}),
        'send 202 response to registrtation');
    is($claim->state(), 'waiting', 'Claim state is waiting');
    ok($claim->timer_watcher, 'Claim created a timer');
    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');
    ok(! $keychain->claim_failed, 'Keychain was not notified about failure');
    is($claim->claim_location_url, $claim_location_url, 'Claim location URL');
}

sub test_registration_response_400 {
    my ($claim, $keychain) = _new_claim_and_keychain();

    $claim->state('registering');

    my $response_handler = $claim->_make_response_generator('claim', 'recv_register_response');
    ok( $response_handler->('', { Status => 400 }),
        'send 400 response to registrtation');
    is($claim->state(), 'failed', 'Claim state is failed');
    ok(! $claim->timer_watcher, 'Claim did not created a timer');
    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');

    my $message = $keychain->claim_failed;
    ok($message, 'Keychain was notified about failure');
    _compare_message_to_expected(
            $message,
            {
                command => 'claim',
                result  => 'failed',
                resource_name => $resource_name,
                error_message => 'bad request',
            });
    ok(! $claim->claim_location_url, 'Claim has no location URL');
}

sub test_send_activating {
    my ($claim, $keychain) = _new_claim_and_keychain();

    $claim->state('waiting');
    my $claim_location_url = $claim->claim_location_url( "${url}/claims/123" );
    ok($claim->send_activating(), 'send_activating()');

    my $params = $claim->_http_method_params();
    my $json = JSON->new();
    _verify_http_params($params,
        [ 'PATCH' => $claim_location_url,
          $json->encode({ status => 'active' }),
          'Content-Type' => 'application/json',
        ]);

    is($claim->state, 'activating', 'state is activating');
    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');
    ok(! $keychain->claim_failed, 'Keychain was not notified about failure');
}

sub test_activating_response_409 {
    my ($claim, $keychain) = _new_claim_and_keychain();
    $claim->state('activating');

    my $fake_timer_watcher = $claim->timer_watcher('abc');
    my $fake_claim_location_url = $claim->claim_location_url("${url}/claim/abc");

    my $response_handler = $claim->_make_response_generator('claim', 'recv_activating_response');
    ok($response_handler->('', { Status => 409 }),
        'send 409 response to activation');

    is($claim->state, 'waiting', 'Claim state is waiting');
    is($claim->timer_watcher, $fake_timer_watcher, 'ttl timer was not changed');
    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');
    ok(! $keychain->claim_failed, 'Keychain was not notified about failure');
    is($claim->claim_location_url, $fake_claim_location_url, 'Claim has a location URL');
}

sub test_activating_response_200 {
    my ($claim, $keychain) = _new_claim_and_keychain();
    $claim->state('activating');
    $claim->ttl(0);

    my $exit_cond = AnyEvent->condvar;
    {
        my $activating_timer = $claim->_create_timer_event(
            after => 1,
            cb    => sub { $exit_cond->send(0,
                'The activating timer fired when it should not have') });
        $claim->timer_watcher( $activating_timer );

        my $fake_claim_location_url =
            $claim->claim_location_url("${url}/claim/abc");
        my $response_handler = $claim->_make_response_generator(
            'claim', 'recv_activating_response');
        ok($response_handler->('', { Status => 200 }),
            'send 200 response to activation');

        is($claim->state, 'active', 'Claim state is active');
        ok($claim->timer_watcher, 'Claim has a ttl timer');
        isnt($claim->timer_watcher, $activating_timer,
            'ttl timer was changed');

        is($keychain->claim_succeeded, $resource_name,
            'Keychain was notified about success');
        ok(! $keychain->claim_failed,
            'Keychain was not notified about failure');
        is($claim->claim_location_url, $fake_claim_location_url,
            'Claim has a location URL');
    }

    $claim->on_send_renewal(sub {$exit_cond->send(1,
        'The activating timer was replaced with the renewal timer')});
    my ($ok, $message) = $exit_cond->recv;
    ok($ok, $message);
}

sub test_activating_response_400 {
    my ($claim, $keychain) = _new_claim_and_keychain();
    $claim->state('activating');

    my $fake_timer_watcher = $claim->timer_watcher('abc');

    my $response_handler = $claim->_make_response_generator('claim', 'recv_activating_response');
    ok($response_handler->('', { Status => 400 }),
        'send 400 response to activation');

    is($claim->state, 'failed', 'Claim state is failed');
    ok(! $claim->timer_watcher, 'Claim has no ttl timer');
    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');

    my $message = $keychain->claim_failed;
    ok($message, 'Keychain was notified about failure');
    _compare_message_to_expected(
            $message,
            {
                command => 'claim',
                result  => 'failed',
                resource_name => $resource_name,
                error_message => 'activating: bad request',
            });
}

sub test_send_renewal {
    my ($claim, $keychain) = _new_claim_and_keychain();

    $claim->state('active');
    my $claim_location_url = $claim->claim_location_url( "${url}/claims/${resource_name}" );
    my $fake_timer_watcher = $claim->timer_watcher('abc');
    ok($claim->send_renewal(), 'send_renewal()');

    my $params = $claim->_http_method_params();
    my $json = JSON->new();
    _verify_http_params($params,
        [ 'PATCH' => $claim_location_url,
          $json->encode({ ttl => $ttl/4}),
          'Content-Type' => 'application/json',
        ]);

    is($claim->state, 'renewing', 'state is renewing');
    is($claim->claim_location_url, $claim_location_url, 'claim location url did not change');
    is($claim->timer_watcher, $fake_timer_watcher, 'ttl timer watcher url did not change');

    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');
    ok(! $keychain->claim_failed, 'Keychain was not notified about failure');
}

sub test_renewal_response_200 {
    my ($claim, $keychain) = _new_claim_and_keychain();
    $claim->state('renewing');

    my $fake_timer_watcher = $claim->timer_watcher('abc');
    my $fake_claim_location_url = $claim->claim_location_url("${url}/claim/abc");

    ok($claim->recv_renewal_response('', { Status => 200 }),
        'send 200 response to renewal');

    is($claim->state, 'active', 'Claim state is active');
    is($claim->timer_watcher, $fake_timer_watcher, 'ttl timer was not changed');
    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');
    ok(! $keychain->claim_failed, 'Keychain was not notified about failure');
    is($claim->claim_location_url, $fake_claim_location_url, 'Claim has a location URL');
}

sub test_renewal_response_400 {
    my ($claim, $keychain) = _new_claim_and_keychain();
    $claim->state('renewing');

    my $fake_timer_watcher = $claim->timer_watcher('abc');

    ok($claim->recv_renewal_response('', { Status => 400 }),
        'send 400 response to renewal');

    is($claim->state, 'failed', 'Claim state is failed');
    ok(! $claim->timer_watcher, 'Claim has no ttl timer');
    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');
    ok(! $keychain->claim_failed, 'Keychain was notified about failure');
    is($keychain->fatal_error_was_called(),
        "claim $resource_name failed renewal with code 400",
        'Keychain was notified with renewal failure with fatal error');
}

sub test_send_release {
    my ($claim, $keychain) = _new_claim_and_keychain();

    $claim->state('active');
    my $claim_location_url = $claim->claim_location_url( "${url}/claims/${resource_name}" );
    my $fake_timer_watcher = $claim->timer_watcher('abc');
    ok($claim->release(), 'send_release()');

    my $params = $claim->_http_method_params();
    my $json = JSON->new();
    _verify_http_params($params,
        [ 'PATCH' => $claim_location_url,
          $json->encode({ status => 'released' }),
          'Content-Type' => 'application/json',
        ]);

    is($claim->state, 'releasing', 'state is releasing');
    is($claim->claim_location_url, $claim_location_url, 'claim location url did not change');
    is($claim->timer_watcher, undef, 'ttl timer watcher was removed');

    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');
    ok(! $keychain->claim_failed, 'Keychain was not notified about failure');
}

sub test_release_response_204 {
    my ($claim, $keychain) = _new_claim_and_keychain();
    $claim->state('releasing');

    my $fake_claim_location_url = $claim->claim_location_url("${url}/claim/abc");

    my $response_handler = $claim->_make_response_generator('claim', 'recv_release_response');
    ok($response_handler->('', { Status => 204 }),
        'send 200 response to release');

    is($claim->state, 'released', 'Claim state is released');
    is($claim->timer_watcher, undef, 'ttl timer was removed');
    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');
    ok(! $keychain->claim_failed, 'Keychain was not notified about failure');
    ok($keychain->release_succeeded, 'Keychain was notified about release success');
    ok(! $keychain->release_failed, 'Keychain was not notified about release success');
    is($claim->claim_location_url, $fake_claim_location_url, 'Claim has a location URL');
}

sub test_release_response_400 {
    my ($claim, $keychain) = _new_claim_and_keychain();
    $claim->state('releasing');

    my $fake_claim_location_url = $claim->claim_location_url("${url}/claim/abc");

    my $response_handler = $claim->_make_response_generator('claim', 'recv_release_response');
    ok($response_handler->('', { Status => 400 }),
        'send 400 response to release');

    is($claim->state, 'failed', 'Claim state is failed');
    is($claim->timer_watcher, undef, 'ttl timer was removed');
    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');
    ok(! $keychain->claim_failed, 'Keychain was not notified about failure');
    ok(! $keychain->release_succeeded, 'Keychain was not notified about release success');

    my $message = $keychain->release_failed;
    ok($message, 'Keychain was notified about failure');
    _compare_message_to_expected(
            $message,
            {
                command => 'release',
                result  => 'failed',
                resource_name => $resource_name,
                error_message => 'release: bad request',
            });
    is($claim->claim_location_url, $fake_claim_location_url, 'Claim has a location URL');
}

sub test_release_response_409 {
    my ($claim, $keychain) = _new_claim_and_keychain();
    $claim->state('releasing');

    my $fake_claim_location_url = $claim->claim_location_url("${url}/claim/abc");

    my $response_handler = $claim->_make_response_generator('claim', 'recv_release_response');
    ok($response_handler->('', { Status => 409 }),
        'send 409 response to release');

    is($claim->state, 'failed', 'Claim state is failed');
    is($claim->timer_watcher, undef, 'ttl timer was removed');
    ok(! $keychain->claim_succeeded, 'Keychain was not notified about success');
    ok(! $keychain->claim_failed, 'Keychain was not notified about failure');
    ok(! $keychain->release_succeeded, 'Keychain was not notified about release success');

    my $message = $keychain->release_failed;
    ok($message, 'Keychain was notified about failure');
    _compare_message_to_expected(
            $message,
            {
                command => 'release',
                result  => 'failed',
                resource_name => $resource_name,
                error_message => 'release: lost claim',
            });
    is($claim->claim_location_url, $fake_claim_location_url, 'Claim has a location URL');
}

sub _compare_message_to_expected {
    my($got, $expected) = @_;

    my $different = '';
    foreach my $k ( keys %$expected ) {
        if ($got->$k ne $expected->{$k}) {
            $different = "got $k >>". $got->$k."<< expected ".$expected->{$k};
        }
    }
    ok(!$different, $different || 'message matched');
}

package Nessy::Keychain::Daemon::TestClaim;
BEGIN {
    our @ISA = qw( Nessy::Keychain::Daemon::Claim );
}

sub new {
    my $class = shift;
    my %params = @_;
    my $expected = delete $params{expected_state_transitions};

    my $self = $class->SUPER::new(%params);
    $self->expected_state_transitions(@$expected) if $expected;
    return $self;
}

sub expected_state_transitions {
    my $self = shift;
    my @expected = @_;
    $self->{_expected_state_transitions} = \@expected;
}

sub remaining_state_transitions {
    return @{shift->{_expected_state_transitions}};
}

sub state {
    my $self = shift;
    unless (@_) {
        return $self->SUPER::state();
    }
    my $next = shift;
    my $expected_next_states = $self->{_expected_state_transitions};
    if ($expected_next_states) {
        Carp::croak("Tried to switch to state $next and there was no expected next state") unless (@$expected_next_states);
        my $expected_next = shift @$expected_next_states;
        Carp::croak("next state $next does not match expected next state $expected_next") unless ($next eq $expected_next);
    }
    $self->SUPER::state($next);
}

sub _send_http_request {
    my $self = shift;
    my @params = @_;

    $self->{_http_method_params} ||= [];
    push @{$self->{_http_method_params}}, \@params;
}

sub _http_method_params {
    return shift->{_http_method_params};
}

sub on_send_renewal {
    my $self = shift;
    if (@_) {
        ($self->{_send_renewal}) = @_;
    }
    return $self->{_send_renewal};
}

sub send_renewal {
    my $self = shift; 

    if (my $cb = $self->on_send_renewal) {
        $self->$cb(@_);
    }
    else {
        $self->SUPER::send_renewal(@_);
    }
}

sub _log_error {
    #Throw out log message
}


package Nessy::Keychain::Daemon::Fake;

sub new {
    my $class = shift;
    return bless {}, $class;
}

BEGIN {
    foreach my $method ( qw( claim_succeeded claim_failed release_succeeded release_failed ) ) {
        my $hash_key = "_${method}";
        my $sub = sub {
            my $self = shift;
            if (@_) {
                $self->{$hash_key} = shift;
            }
            return $self->{$hash_key};
        };
        no strict 'refs';
        *$method = $sub;
    }
}

sub fatal_error {
    my($self, $message) = @_;
    $self->{_fatal_error_message} = $message;
}

sub fatal_error_was_called {
    return shift->{_fatal_error_message};
}



