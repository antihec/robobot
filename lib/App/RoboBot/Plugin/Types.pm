package App::RoboBot::Plugin::Types;

use v5.20;

use namespace::autoclean;

use Moose;

use Scalar::Util qw( blessed );

use App::RoboBot::Type::String;

extends 'App::RoboBot::Plugin';

=head1 types

Provides common functions for interacting with types.

=cut

has '+name' => (
    default => 'Types',
);

has '+description' => (
    default => 'Provides common functions for interacting with types.',
);

=head2 typeof

=head3 Description

Returns a string containing the type name of ``value``.

=head3 Usage

<value>

=cut

has '+commands' => (
    default => sub {{
        'ast'    => { method => 'types_ast', preprocess_args => 0 },
        'typeof' => { method => 'types_typeof' },
    }},
);

sub types_ast {
    my ($self, $message, $command, $rpl, @args) = @_;

    my @asts;

    foreach my $expr (@args) {
        if (defined $expr && blessed($expr) && $expr->can('ast')) {
            push(@asts, $expr->ast);
        } else {
            push(@asts, 'nil');
        }
    }

    return @asts;
}

sub types_typeof {
    my ($self, $message, $command, $rpl, $var) = @_;

    return unless defined $var;

    my $type;
    eval {
        $type = $var->type;
    };

    return if $@;
    return App::RoboBot::Type::String->new( value => $type );
}

__PACKAGE__->meta->make_immutable;

1;
