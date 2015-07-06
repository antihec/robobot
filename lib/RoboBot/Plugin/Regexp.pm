package RoboBot::Plugin::Regexp;

use v5.20;

use namespace::autoclean;

use Moose;
use MooseX::SetOnce;

extends 'RoboBot::Plugin';

has '+name' => (
    default => 'Regexp',
);

has '+description' => (
    default => 'Regular expression matching and substitution functions.',
);

has '+commands' => (
    default => sub {{
        'match' => { method      => 're_match',
                     description => 'Returns a list of matches from the given text for the supplied pattern. PCRE modifiers "i" and "g" are implied.',
                     usage       => '<pattern> <text>',
                     example     => '"\d+" "The year 2014 saw precisely 10 things happen."',
                     result      => '("2014" "10")' },

        'replace' => { method      => 're_replace',
                       description => 'Replaces any matches of pattern in the given text with the given string. PCRE modifiers "i" and "g" are implied.',
                       usage       => '<pattern> <replacement> <text>',
                       example     => '"hundred" "billion" "You have won a hundred dollars!"',
                       result      => 'You have won a billion dollars!' },
    }},
);

sub re_match {
    my ($self, $message, $command, $pattern, @args) = @_;

    unless ($pattern = $self->cleanup_pattern($pattern)) {
        $message->response->raise('Invalid regular expression provided.');
        return;
    }

    my @matches;

    foreach my $text (@args) {
        eval {
            push(@matches, $text =~ m{$pattern}ig);
        };

        if ($@) {
            $message->response->raise('Could not evaluate your regular expression.');
            return;
        }
    }

    return @matches;
}

sub re_replace {
    my ($self, $message, $command, $pattern, $replace, @args) = @_;

    unless ($pattern = $self->cleanup_pattern($pattern)) {
        $message->response->raise('Invalid regular expression provided.');
        return;
    }

    return unless @args && @args > 0;

    # TODO change function to not pre-process args, so that matches may be set as variables which
    # can be interpolated in the replacement string.

    foreach my $line (@args) {
        eval {
            $line =~ s{$pattern}{$replace}ig;
        };

        if ($@) {
            $message->response->raise('Could not evaluate your regular expression substitution.');
            return;
        }
    }

    return @args;
}

sub cleanup_pattern {
    my ($self, $pattern) = @_;

    return unless defined $pattern && length($pattern) > 0;

    foreach my $m ((['/','/'],['{','}'])) {
        my ($l, $r) = ($m->[0], $m->[1]);

        if ($pattern =~ s{^$l(.*)$r[igexs]*$}{$1}is) {
            # don't replace outer enclosing braces more than once, in case one
            # style was chosen specifically to allow a pattern to otherwise be
            # wrapped in another that isn't intended to be the matching delimiters
            last;
        }
    }

    return $pattern;
}

__PACKAGE__->meta->make_immutable;

1;
