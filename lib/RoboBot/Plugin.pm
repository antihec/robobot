package RoboBot::Plugin;

use v5.20;

use namespace::autoclean;

use Moose;
use MooseX::SetOnce;

use Data::Dumper;
use Scalar::Util qw( blessed );

has 'name' => (
    is  => 'ro',
    isa => 'Str',
);

has 'description' => (
    is        => 'ro',
    isa       => 'Str',
    predicate => 'has_description',
);

has 'commands' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { return {} },
);

has 'before_hook' => (
    is        => 'ro',
    isa       => 'Str',
    predicate => 'has_before_hook',
);

has 'after_hook' => (
    is        => 'ro',
    isa       => 'Str',
    predicate => 'has_after_hook',
);

has 'bot' => (
    is     => 'rw',
    isa    => 'RoboBot',
    traits => [qw( SetOnce )],
);

sub init {
    my ($self, $bot) = @_;
}

sub post_init {
    my ($self, $bot) = @_;
}

sub ns {
    my ($self) = @_;

    my $ns = lc($self->name);
    $ns =~ s{::}{.}g;

    return $ns;
}

sub process {
    my ($self, $message, $command, $rpl, @args) = @_;

    # Short-circuit if this plugin is disabled on the current message's network.
    return if exists $message->network->disabled_plugins->{lc($self->name)};

    # Remove namespace from command if present (by the time we reach this point, we
    # already know what plugin namespace we're in)
    if ($command =~ m{/(.*)$}) {
        $command = $1;
    }
    $command = lc($command);

    return $message->response->raise("Invalid command processor executed.")
        unless exists $self->commands->{$command};

    my $method = $self->commands->{$command}{'method'};

    # Ensure that the nick is permitted to call the function.
    if (exists $message->sender->denied_functions->{$command}) {
        return $message->response->raise('You are not permitted to call the function (%s).', $command);
    }

    # If the function takes "keyed" arguments (e.g. a Symbol followed by an
    # expression or value) extract those now into a hash that will be passed
    # to the function's implementation separately from any remainder arguments.
    my $keyed = {};
    if ($self->commands->{$command}{'keyed_args'}) {
        ($keyed, @args) = $self->extract_keyed_args($message, $rpl, @args);
    }

    # By default, we pre-process all arguments, but some plugins can opt out
    # of this to handle things like conditional evaluations or loops
    unless (exists $self->commands->{$command}{'preprocess_args'} && $self->commands->{$command}{'preprocess_args'} == 0) {
        # TODO: There are much better ways of deciding how to pass a symbol
        #       that happens to have the name of a function as a function, or
        #       as a string, than this.
        my $pass_funcs = exists $self->commands->{$command}{'take_funcs'} && $self->commands->{$command}{'take_funcs'} == 1 ? 1 : 0;

        my @new_args;

        foreach my $arg (@args) {
            if (blessed($arg) && $arg->can('evaluate')) {
                if (($arg->type eq 'Function' || $arg->type eq 'Macro') && !$pass_funcs) {
                    push(@new_args, $arg->value);
                } else {
                    push(@new_args, $arg->evaluate($message, $rpl));
                }
            } else {
                push(@new_args, $arg);
            }
        }

        @args = @new_args;
    }

    if ($self->commands->{$command}{'keyed_args'}) {
        return $self->$method($message, $command, $rpl, $keyed, @args);
    } else {
        return $self->$method($message, $command, $rpl, @args);
    }
}

sub hook_before {
    my ($self, $message) = @_;

    return $message unless $self->has_before_hook;

    my $hook = $self->before_hook;
    return $self->$hook($message);
}

sub hook_after {
    my ($self, $message) = @_;

    return $message unless $self->has_after_hook;

    my $hook = $self->after_hook;
    return $self->$hook($message);
}

sub extract_keyed_args {
    my ($self, $message, $rpl, @args) = @_;

    my %keyed = ();
    my @remaining;

    while (@args) {
        my $k = shift(@args);
        if ($k->type eq 'Symbol') {
            $keyed{$k->value}
                = @args && $args[0]->type ne 'Symbol'
                ? shift(@args)->evaluate($message, $rpl)
                : 1;
        } else {
            push(@remaining, $k);
        }
    }

    return (\%keyed, @remaining);
}

__PACKAGE__->meta->make_immutable;

1;
