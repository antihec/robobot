package RoboBot::Plugin::Thinge;

use strict;
use warnings FATAL => 'all';

use Moose;
use namespace::autoclean;

extends 'RoboBot::Plugin';

has '+name' => (
    default => 'Thinge',
);

has '+description' => (
    default => 'Provides generalized functions for saving, recalling, and tagging links, quotes, etc.',
);

has '+commands' => (
    default => sub {{
        'thinge' => { method      => 'thinge',
                      description => 'Returns a specific thinge (when the <id> is given), a random thinge with a particular tag (when <tag> is given), or a random thinge of <type> from the collection (when only <type> is provided).',
                      usage       => '<type> [<id> | <tag>]' },

        'thinge-add' => { method      => 'save_thinge',
                          description => 'Saves a thinge to the collection and reports its ID.',
                          usage       => '<type> "<text>"' },

        'thinge-delete' => { method      => 'delete_thinge',
                             description => 'Removes the specified thinge from the collection.',
                             usage       => '<type> <id>' },

        'thinge-tag' => { method      => 'tag_thinge',
                          description => 'Tags the specified thinge with the given list of tags.',
                          usage       => '<type> <id> "<tag>" ["<tag 2>" ... "<tag N>"]' },

        'thinge-types' => { method      => "show_types",
                            description => 'Lists the current types of thinges which have collections.',
                            usage       => '' },
    }},
);

has 'type_ids' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

sub init {
    my ($self) = @_;

    my $res = $self->bot->config->db->do(q{
        select id, name
        from thinge_types
    });

    if ($res) {
        while ($res->next) {
            $self->type_ids->{$res->{'name'}} = $res->{'id'};
        }
    }
}

sub thinge {
    my ($self, $message, $command, $type, $id_or_tag) = @_;

    my $type_id = $self->get_type_id($message, $type) || return;

    my ($res);

    if (defined $id_or_tag) {
        if ($id_or_tag =~ m{^\d+$}o) {
            $res = $self->bot->config->db->do(q{
                select t.id, t.thinge_num, t.thinge_url, n.nick,
                    to_char(t.added_at, 'FMDay, FMMonth FMDDth, YYYY') as added_date,
                    to_char(t.added_at, 'FMHH12:MIpm') as added_time
                from thinge_thinges t
                    join nicks n on (n.id = t.added_by)
                where t.type_id = ? and t.thinge_num = ?
            }, $type_id, $id_or_tag);
        } else {
            $id_or_tag =~ s{^\#+}{}ogs;

            $res = $self->bot->config->db->do(q{
                select t.id, t.thinge_num, t.thinge_url, n.nick,
                    to_char(t.added_at, 'FMDay, FMMonth FMDDth, YYYY') as added_date,
                    to_char(t.added_at, 'FMHH12:MIpm') as added_time
                from thinge_thinges t
                    join nicks n on (n.id = t.added_by)
                    join thinge_thinge_tags ttg on (ttg.thinge_id = t.id)
                    join thinge_tags tg on (tg.id = ttg.tag_id)
                where t.type_id = ?
                    and lower(tg.tag_name) = lower(?)
                order by random()
                limit 1
            }, $type_id, $id_or_tag);
        }
    } else {
        $res = $self->bot->config->db->do(q{
            select t.id, t.thinge_num, t.thinge_url, n.nick,
                to_char(t.added_at, 'FMDay, FMMonth FMDDth, YYYY') as added_date,
                to_char(t.added_at, 'FMHH12:MIpm') as added_time
            from thinge_thinges t
                join nicks n on (n.id = t.added_by)
            where t.type_id = ?
            order by random()
            limit 1
        }, $type_id);
    }

    unless ($res && $res->next) {
        $message->response->raise('Could not locate a %s that matched your request.', $type);
        return;
    }

    $message->response->push(sprintf('[%d] %s', $res->{'thinge_num'}, $res->{'thinge_url'}));
    $message->response->push(sprintf('Added by <%s> on %s at %s.', $res->{'nick'}, $res->{'added_date'}, $res->{'added_time'}));

    $res = $self->bot->config->db->do(q{
        select tg.tag_name
        from thinge_tags tg
            join thinge_thinge_tags ttg on (ttg.tag_id = tg.id)
        where ttg.thinge_id = ?
        order by tg.tag_name asc
    }, $res->{'id'});

    my @tags;

    if ($res) {
        while ($res->next) {
            push(@tags, $res->{'tag_name'});
        }
    }

    if (@tags && @tags > 0) {
        $message->response->push(sprintf('Tags: %s', join(' ', map { "\#$_" } @tags)));
    }

    return;
}

sub save_thinge {
    my ($self, $message, $command, $type, $text) = @_;

    return unless defined $text && $text =~ m{\w+}o;
    $text =~ s{(^\s+|\s+$)}{}ogs;

    my $type_id = $self->get_type_id($message, $type) || return;

    my $res = $self->bot->config->db->do(q{
        select id, thinge_num
        from thinge_thinges
        where type_id = ? and lower(thinge_url) = lower(?)
    }, $type_id, $text);

    if ($res && $res->next) {
        $message->response->push(sprintf('That %s has already been saved as ID %d.', $type, $res->{'thinge_num'}));
        return;
    }

    $res = $self->bot->config->db->do(q{
        insert into thinge_thinges (type_id, thinge_url, added_by, added_at, thinge_num)
        values (?, ?, ?, now(), (select max(thinge_num) + 1 from thinge_thinges where type_id = ?))
        returning thinge_num
    }, $type_id, $text, $message->sender->id, $type_id);

    if ($res && $res->next) {
        $message->response->push(sprintf('Your %s has been saved to the collection as ID %d.', $type, $res->{'thinge_num'}));
    } else {
        $message->response->raise('Could not save your %s. Please try again.', $type);
    }

    return;
}

sub delete_thinge {
    my ($self, $message, $command, $type, $thinge_id) = @_;

    return unless defined $thinge_id && $thinge_id =~ m{^\d+$}o;

    my $type_id = $self->get_type_id($message, $type) || return;

    my $res = $self->bot->config->db->do(q{
        delete from thinge_thinges
        where type_id = ? and thinge_num = ?
        returning id
    }, $type_id, $thinge_id);

    if ($res && $res->next) {
        $message->response->push(sprintf('%s%s %d deleted.', uc(substr($type, 0, 1)), substr($type, 1), $thinge_id));
    } else {
        $message->response->raise('No such %s existed.', $type);
    }

    return;
}

sub tag_thinge {
    my ($self, $message, $command, $type, $id, @tags) = @_;

    my $type_id = $self->get_type_id($message, $type) || return;

    my $res = $self->bot->config->db->do(q{
        select id
        from thinge_thinges
        where type_id = ? and thinge_num = ?
    }, $type_id, $id);

    unless ($res && $res->next) {
        $message->response->raise('There is no such %s with an ID %d.', $type, $id);
        return;
    }

    my $thinge_id = $res->{'id'};

    my ($tag_id);

    foreach my $tag (@tags) {
        if (($tag_id, $tag) = $self->get_tag_id($message, $tag)) {
            $self->bot->config->db->do(q{
                insert into thinge_thinge_tags ???
            }, { thinge_id => $thinge_id, tag_id => $tag_id });
        }
    }

    $message->response->push(sprintf('%s%s has been tagged with %s.', uc(substr($type, 0, 1)), substr($type, 1),
        join(', ', map { "\#$_" } @tags)));

    return;
}

sub show_types {
    my ($self, $message) = @_;

    my $res = $self->bot->config->db->do(q{
        select name
        from thinge_types
        order by name asc
    });

    if ($res) {
        my @types;
        while ($res->next) {
            push(@types, $res->{'name'});
        }

        $message->response->push('The following thinge types are currently known:');
        $message->response->push(join(', ', @types));
    }

    return;
}

sub get_tag_id {
    my ($self, $message, $tag) = @_;

    $tag =~ s{^\#+}{}ogs;
    $tag =~ s{(^\s+|\s+$)}{}ogs;
    $tag =~ s{\s+}{-}ogs;

    my $res = $self->bot->config->db->do(q{
        select id
        from thinge_tags
        where lower(tag_name) = lower(?)
    }, $tag);

    if ($res && $res->next) {
        return ($res->{'id'}, $tag);
    } else {
        $res = $self->bot->config->db->do(q{
            insert into thinge_tags ??? returning id
        }, { tag => $tag });

        if ($res && $res->next) {
            return ($res->{'id'}, $tag);
        }
    }

    return;
}

sub get_type_id {
    my ($self, $message, $type) = @_;

    my ($type_id);
    $type = lc($type);

    return $self->type_ids->{$type} if exists $self->type_ids->{$type};

    my $res = $self->bot->config->db->do(q{
        select id
        from thinge_types
        where lower(name) = lower(?)
    }, $type);

    if ($res && $res->next) {
        $type_id = $res->{'id'};
    } else {
        $res = $self->bot->config->db->do(q{
            insert into thinge_types ??? returning id
        }, { name => $type });

        if ($res && $res->next) {
            $type_id = $res->{'id'};
        } else {
            $message->response->raise('Could not locate an ID for thinge type: %s', $type);
            return;
        }
    }

    $self->type_ids->{$type} = $type_id;
    return $type_id;
}

__PACKAGE__->meta->make_immutable;

1;