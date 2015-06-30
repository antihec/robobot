package RoboBot::Response;

use strict;
use warnings FATAL => 'all';

use Moose;
use MooseX::SetOnce;
use namespace::autoclean;

has 'content' => (
    is        => 'rw',
    isa       => 'ArrayRef[Str]',
    predicate => 'has_content',
    clearer   => 'clear_content',
);

has 'network' => (
    is        => 'rw',
    isa       => 'RoboBot::Network',
    predicate => 'has_network',
    clearer   => 'clear_network',
);

has 'channel' => (
    is        => 'rw',
    isa       => 'RoboBot::Channel',
    predicate => 'has_channel',
    clearer   => 'clear_channel',
);

has 'nick' => (
    is        => 'rw',
    isa       => 'RoboBot::Nick',
    predicate => 'has_nick',
    clearer   => 'clear_nick',
);

has 'error' => (
    is        => 'rw',
    isa       => 'Str',
    predicate => 'has_error',
    clearer   => 'clear_error',
);

has 'collapsible' => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);

has 'bot' => (
    is  => 'ro',
    isa => 'RoboBot',
);

sub raise {
    my ($self, $format, @args) = @_;

    if (@args && @args > 0) {
        # TODO: improve handling of sprintf errors (mismatched args, etc.)
        $self->error(sprintf($format, @args));
    } else {
        $self->error($format);
    }

    $self->push("Error: " . $self->error);
    $self->send;
}

sub send {
    my ($self) = @_;

    return unless $self->has_content;

    # Delegate sending to network protocol plugin, since length limits and
    # features like multi-line output vary.
    my @r = $self->network->send($self);

    # Reset the response's collapsible flag to 0 for new content.
    $self->collapsible(0);

    return @r;
}

sub push {
    my ($self, @args) = @_;

    if (@args && @args > 0) {
        # Need to force all arguments into a stringy scalar to pass the
        # ArrayRef[Str] constraint on content, as some function may include
        # one or more of their own arguments in the push(), still blessed as a
        # Data::SExpression object.
        if ($self->has_content) {
            push(@{$self->content}, map { "$_" } @args);
        } else {
            $self->content([map { "$_" } @args]);
        }
    }
}

sub pop {
    my ($self) = @_;

    if ($self->has_content) {
        return pop(@{$self->content});
    }
}

sub shift {
    my ($self) = @_;

    if ($self->has_content) {
        return shift(@{$self->content});
    }
}

sub unshift {
    my ($self, @args) = @_;

    if (@args && @args > 0) {
        if ($self->has_content) {
            unshift(@{$self->content}, @args);
        } else {
            $self->content(\@args);
        }
    }
}

sub num_lines {
    my ($self) = @_;

    return 0 unless $self->has_content;
    return scalar(@{$self->content});
}

__PACKAGE__->meta->make_immutable;

1;
