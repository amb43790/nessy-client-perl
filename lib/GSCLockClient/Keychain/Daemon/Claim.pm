package GSCLockClient::Keychain::Daemon::Claim;

use strict;
use warnings;

use GSCLockClient::Properties qw(resource_name state url claim_location_url keychain ttl_timer_watcher ttl);

use AnyEvent;
use AnyEvent::HTTP;
use JSON;
use Data::Dumper;
use Sub::Name;
use Sub::Install;

use constant STATE_NEW          => 'new';
use constant STATE_REGISTERING  => 'registering';
use constant STATE_WAITING      => 'waiting';
use constant STATE_ACTIVATING   => 'activating';
use constant STATE_ACTIVE       => 'active';
use constant STATE_RENEWING     => 'renewing';
use constant STATE_RELEASED     => 'released';
use constant STATE_RELEASING    => 'releasing';
use constant STATE_FAILED       => 'failed';

my %STATE = (
    STATE_NEW()         => [ STATE_REGISTERING ],
    STATE_REGISTERING() => [ STATE_WAITING, STATE_ACTIVE ],
    STATE_WAITING()     => [ STATE_ACTIVATING ],
    STATE_ACTIVATING()  => [ STATE_ACTIVE, STATE_WAITING ],
    STATE_ACTIVE()      => [ STATE_RENEWING, STATE_RELEASING ],
    STATE_RELEASING()   => [ STATE_RELEASED ],
    STATE_RENEWING()    => [ STATE_ACTIVE ],
    STATE_FAILED()      => [],
    STATE_RELEASED()    => [],
);


my $json_parser = JSON->new();
sub new {
    my($class, %params) = @_;

    my $self = bless {}, $class;

    $self->_required_params(\%params, qw(url resource_name keychain ttl));
    $self->state(STATE_NEW);
    return $self;
}

sub start {
    my $self = shift;

    $self->send_register();
}

sub release {

}

sub transition {
    my($self, $new_state) = @_;

    my @allowed_next = @{ $STATE{ $self->state } };
    foreach my $allowed_next ( @allowed_next ) {
        if ($allowed_next eq $new_state) {
            $self->state($new_state);
            return 1;
        }
    }
    $self->_failure(Carp::shortmess("Illegal transition from ".$self->state." to $new_state"));
}

sub _failure {
    my($self, $error) = @_;

    my $message = { resource_name => $self->resource_name };
    $error && ($message->{error_message} = $error);

    $self->keychain->claim_failed($message);
}

sub _success {
    my $self = shift;

    $self->keychain->claim_succeeded({ resource_name => $self->resource_name });
}

sub send_register {
    my $self = shift;

    $self->_send_http_request(
        POST => $self->url . '/claims',
        $json_parser->encode({ resource => $self->resource_name }),
        'Content-Type' => 'application/json',
        sub { $self->recv_register_response(@_) }
    );
    $self->transition(STATE_REGISTERING);
}

sub _send_http_request {
    my $self = shift;
    my $method = shift;
    my $url = shift;
    my $body = shift;
    my @headers = @_;
    my $cb = pop @headers;

    AnyEvent::HTTP::http_request($method => $url, $body, @headers, $cb);
}

# make handlers for receiving responses and forwarding them to individual handlers
# by response code
foreach my $prefix ( qw( recv_register_response ) ) {
    my $sub = Sub::Name::subname $prefix => sub {
        my($self, $body, $headers) = @_;

        my $status = $headers->{Status};
        my $method = "${prefix}_${status}";

        unless (eval { $self->$method($body, $headers); }) {
             $self->_failure("Exception when handling status $status in ${prefix}(): $@\n"
                 . "Headers: " . Data::Dumper::Dumper($headers) ."\n"
                   . "Body: " . Data::Dumper::Dumper($body)
             );
        }
    };
    Sub::Install::install_sub({
        code => $sub,
        into => __PACKAGE__,
        as => $prefix,
    });
}

sub recv_register_response_201 {
    my($self, $body, $headers) = @_;
    $self->transition(STATE_ACTIVE);

    $self->claim_location_url( $headers->{Location} );
    my $ttl = $self->_ttl_timer_value;
    my $w = $self->_create_timer_event(
                after => $ttl,
                interval => $ttl,
                cb => sub { $self->send_renewal() }
            );
    $self->ttl_timer_watcher($w);

    $self->_success();
}

sub recv_register_response_202 {
    my($self, $body, $headers) = @_;

    $self->transition(STATE_WAITING);

    $self->claim_location_url( $headers->{Location} );
    my $ttl = $self->_ttl_timer_value;
    my $w = $self->_create_timer_event(
                after => $ttl,
                interval => $ttl,
                cb => sub { $self->send_activating() }
            );
    $self->ttl_timer_watcher($w);
}

sub recv_register_response_400 {
    shift->state_fail();
}

sub _create_timer_event {
    my $self = shift;

    AnyEvent->timer(@_);
}

sub _ttl_timer_value {
    my $self = shift;
    return $self->ttl / 4;
}

sub state_fail {
    my $self = shift;
    $self->state(STATE_FAILED);
    $self->keychain->claim_failed( { resource_name => $self->resource_name });
}




1;
