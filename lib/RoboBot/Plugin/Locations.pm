package RoboBot::Plugin::Locations;

use v5.20;

use namespace::autoclean;

use Moose;

extends 'RoboBot::Plugin';

has '+name' => (
    default => 'Locations',
);

has '+description' => (
    default => 'Provides functions for tracking where you are located.',
);

has '+commands' => (
    default => sub {{
        'set-location' => { method      => 'location_set',
                            description => 'Sets your most recent location, along with an optional message, which others may view with the (where-is) function.',
                            usage       => '<location name> [<detailed message>]',
                            example     => '"Working from home" "doc appt this afternoon, taking an extended lunch"' },

        'where-is' => { method      => 'location_nick',
                        description => 'Displays the last-registered location for <nick>, along with any optional message they may have left.',
                        usage       => '<nick>' },
    }},
);

sub location_set {
    my ($self, $message, $command, $location, @details) = @_;

    unless (defined $location && $location =~ m{\w+}) {
        $message->response->raise('You must provide a location name.');
        return;
    }

    my $detail_msg = @details && @details > 0 ? join(' ', @details) : undef;

    my $res = $self->bot->config->db->do(q{
        insert into locations ??? returning *
    }, {
        network_id  => $message->network->id,
        nick_id     => $message->sender->id,
        loc_name    => $location,
        loc_message => $detail_msg,
    });

    unless ($res && $res->next) {
        $message->response->raise('Could not set your location. Please try again.');
        return;
    }

    $message->response->push('Your location has been updated.');
    return;
}

sub location_nick {
    my ($self, $message, $command, $name) = @_;

    unless (defined $name && $name =~ m{\w+}) {
        $message->response->raise('You must provide the name of the person whose location you want to see.');
        return;
    }

    my $res = $self->bot->config->db->do(q{
        select n.name, l.loc_name, l.loc_message, l.created_at
        from locations l
            join nicks n on (n.id = l.nick_id)
        where l.network_id = ?
            and n.name ilike ?
        order by l.created_at desc
        limit 1
    }, $message->network->id, "%${name}%");

    unless ($res && $res->next) {
        $message->response->push(sprintf('No location information found for %s.', $name));
        return;
    }

    $message->response->push(sprintf('*%s*: %s', $res->{'name'}, $res->{'loc_name'}));
    $message->response->push(sprintf('Details: %s', $res->{'loc_message'})) if $res->{'loc_message'};
    $message->response->push(sprintf('Last updated: %s', $res->{'created_at'}));

    return;
}

__PACKAGE__->meta->make_immutable;

1;
