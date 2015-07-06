package RoboBot::Plugin::Github;

use v5.20;

use namespace::autoclean;

use Moose;
use MooseX::SetOnce;

use AnyEvent;
use JSON;
use LWP::UserAgent;
use URI;

use RoboBot::Channel;
use RoboBot::Response;

extends 'RoboBot::Plugin';

has '+name' => (
    default => 'Github',
);

has '+description' => (
    default => 'Provides functions for interacting with Github APIs, including watching for repository related events.',
);

has '+commands' => (
    default => sub {{
        'github-watch' => { method      => 'add_repo_watcher',
                            description => 'Adds a watcher event for this channel, subscribing to commits, issues, and pull requests to the named Github repository.',
                            usage       => '<repo url>', },

        'github-unwatch' => { method      => 'remove_repo_watcher',
                              description => 'Removes a watcher for the named Github repository on this channel.',
                              usage       => '<repo url>', },

        'github-list' => { method      => 'list_repo_watchers',
                           description => 'Lists the Github repositories currently being watched for this channel.',
                           usage       => '' },
    }},
);

has 'watcher' => (
    is => 'rw',
);

has 'ua' => (
    is      => 'rw',
    isa     => 'LWP::UserAgent',
    default => sub {
        my $ua = LWP::UserAgent->new;
        $ua->agent('RoboBot/'.$RoboBot::VERSION.' ');
        $ua->timeout(5);
        return $ua;
    },
);

sub init {
    my ($self, $bot) = @_;

    # Add API authorization info to our user agent if it was present in the
    # configuration file.
    if (exists $bot->config->plugins->{'github'}) {
        if (exists $bot->config->plugins->{'github'}{'user'} && exists $bot->config->plugins->{'github'}{'token'}) {
            $self->ua->credentials(
                'api.github.com:443',
                '',
                $bot->config->plugins->{'github'}{'user'},
                $bot->config->plugins->{'github'}{'token'}
            );
        }
    }

    # Kick off the watcher with a short delay for the first check, to give the
    # bot a little time to settle into things before firing off notifications
    # in channels.
    $self->watcher(
        AnyEvent->timer(
            after => 30,
            cb    => sub { $self->_run_watcher($bot) },
        )
    );
}

sub list_repo_watchers {
    my ($self, $message, $command) = @_;

    unless ($message->has_channel) {
        $message->response->raise('Only channels may have Github repository watchers.');
        return;
    }

    my $res = $self->bot->config->db->do(q{
        select r.repo_id, r.owner_name, r.repo_name
        from github_repos r
            join github_repo_channels c on (c.repo_id = r.repo_id)
        where c.channel_id = ?
        order by r.owner_name asc, r.repo_name asc
    }, $message->channel->id);

    if ($res && $res->count > 0) {
        $message->response->push(sprintf('%d Github %s being watched in this channel:', $res->count, ($res->count == 1 ? 'repository is' : 'repositories are')));

        while ($res->next) {
            $message->response->push(sprintf('https://github.com/%s/%s', $res->{'owner_name'}, $res->{'repo_name'}));
        }
    } else {
        $message->response->push('There are no Github repositories being watched for this channel.');
    }

    return;
}

sub add_repo_watcher {
    my ($self, $message, $command, @repo_urls) = @_;

    unless ($message->has_channel) {
        $message->response->raise('Cannot add Github repository watchers without a channel.');
        return;
    }

    REPO:
    foreach my $url (@repo_urls) {
        $url = $self->clean_repo_url($url);
        my ($owner_name, $repo_name) = $self->get_repo_parts($url);

        unless (defined $owner_name && defined $repo_name) {
            $message->response->raise('"%s" does not appear to be a valid Github repository URL.', $url);
            next REPO;
        }

        my $repo = $self->bot->config->db->do(q{
            select repo_id
            from github_repos
            where lower(owner_name) = lower(?) and lower(repo_name) = lower(?)
        }, $owner_name, $repo_name);

        unless ($repo && $repo->next) {
            $repo = $self->bot->config->db->do(q{
                insert into github_repos ??? returning repo_id
            }, { owner_name => $owner_name,
                 repo_name  => $repo_name,
            });

            unless ($repo && $repo->next) {
                $message->response->raise('Could not add a watcher for the Github repo "%s". Please check your URL and try again.', $url);
                next REPO;
            }
        }

        my $res = $self->bot->config->db->do(q{
            select * from github_repo_channels where repo_id = ? and channel_id = ?
        }, $repo->{'repo_id'}, $message->channel->id);

        if ($res && $res->next) {
            $message->response->push(sprintf('The repository at %s is already being watched in this channel.', $url));
        } else {
            $self->bot->config->db->do(q{
                insert into github_repo_channels ???
            }, { repo_id => $repo->{'repo_id'}, channel_id => $message->channel->id });

            $message->response->push(sprintf('The Github repository at %s has been added to this channel\'s watch list.', $url));
        }
    }

    return;
}

sub remove_repo_watcher {
    my ($self, $message, $command, @repo_urls) = @_;

    unless ($message->has_channel) {
        $message->response->raise('Cannot remove Github repository watchers from a non-channel context.');
        return;
    }

    REPO:
    foreach my $url (@repo_urls) {
        $url = $self->clean_repo_url($url);
        my ($owner_name, $repo_name) = $self->get_repo_parts($url);

        unless (defined $owner_name && defined $repo_name) {
            $message->response->raise('"%s" does not appear to be a valid Github repository URL.', $url);
            return;
        }

        my $repo = $self->bot->config->db->do(q{
            select repo_id
            from github_repos
            where lower(owner_name) = lower(?) and lower(repo_name) = lower(?)
        }, $owner_name, $repo_name);

        if ($repo && $repo->next) {
            my $res = $self->bot->config->db->do(q{
                delete from github_repo_channels where repo_id = ? and channel_id = ? returning *
            }, $repo->{'repo_id'}, $message->channel->id);

            if ($res) {
                if ($res->next) {
                    $message->response->push(sprintf('I will no longer notify this channel about events from %s.', $url));
                    next REPO;
                } else {
                    $message->response->raise('I was not watching %s for this channel.', $url);
                    next REPO;
                }
            } else {
                $message->response->raise('Encountered an error when attempting to remove this channel\'s watcher for %s.', $url);
                next REPO;
            }
        } else {
            $message->response->raise('"%s" is not a Github repository that I have been watching.', $url);
            next REPO;
        }
    }

    return;
}

sub clean_repo_url {
    my ($self, $url) = @_;

    $url =~ s{(^\<|\>$)}{}gs;
    $url =~ s{\.git(/|$)}{$1}s;

    return $url;
}

sub get_repo_parts {
    my ($self, $url) = @_;

    if ($url =~ m{github\.com/([^/]+)/([^/]+)(?:\.git)?}i) {
        return ($1, $2);
    }

    return;
}

sub get_repo_notices {
    my ($self, $repo) = @_;

    my ($json, @notices);

    my $api_path = ['repos',$repo->{'owner_name'},$repo->{'repo_name'},'commits'];
    my $api_args = { since => $repo->{'polled_at'} };

    if ($json = $self->make_gh_api_call($api_path,$api_args)) {
        if (ref($json) eq 'ARRAY' && @{$json} > 0) {
            my %commiters;
            my @commits;

            foreach my $commit (@{$json}) {
                $commiters{$commit->{'commit'}{'author'}{'email'}}
                    =    $commit->{'commit'}{'author'}{'name'}
                      // $commit->{'commit'}{'author'}{'email'}
                    if exists $commit->{'commit'}{'author'}{'email'};

                push(@commits, {
                    # TODO: proper commit hash shortening (problem: requires git
                    #       repo access to ensure uniqueness of short hash)
                    id      => substr($commit->{'sha'}, 0, 10),
                    comment => $self->short_commit_comment($commit->{'commit'}{'message'}),
                    url     => $commit->{'commit'}{'html_url'},
                    author  => $commit->{'commit'}{'author'}{'name'} // $commit->{'commit'}{'author'}{'email'},
                });
            }

            push(@notices, sprintf('[%s/%s] %d new commit%s by %s.',
                $repo->{'owner_name'}, $repo->{'repo_name'},
                scalar(@commits), (scalar(@commits) == 1 ? '' : 's'),
                join(', ', sort { $a cmp $b } values %commiters)));
            push(@notices, sprintf('> %s: %s - %s',
                $_->{'id'}, $_->{'comment'}, $_->{'author'})) foreach @commits;
        }
    }

    return @notices;
}

sub short_commit_comment {
    my ($self, $comment) = @_;

    return '' unless defined $comment && length($comment) > 0;

    # Remove anything past the first newline if this was a multi-line comment.
    $comment = (grep { $_ =~ m{.+} } split(/\n/, $comment))[0];

    # Truncate and add ellipses.
    if (length($comment) > 64) {
        $comment = substr($comment, 0, 62) . '...';
    }

    return $comment;
}

sub make_gh_api_call {
    my ($self, $path, $args) = @_;

    my $uri = URI->new;
    $uri->scheme('https');
    $uri->host('api.github.com');

    if (ref($path) eq 'ARRAY') {
        $uri->path_segments(@{$path});
    } else {
        $uri->path($path);
    }

    if (defined $args && ref($args) eq 'HASH' && scalar(keys(%{$args})) > 0) {
        $uri->query_form($args);
    }

    my $response = $self->ua->get($uri->as_string);

    return unless $response->is_success;

    my $json;
    eval {
        $json = json_decode($response->decoded_content);
    };

    return if $@;
    return $json;
}

sub _run_watcher {
    my ($self, $bot) = @_;

    my $repos = $bot->config->db->do(q{
        select r.repo_id, r.owner_name, r.repo_name, r.last_pr, r.last_issue,
            to_char(coalesce(r.polled_at, now() - interval '55 min') at time zone 'UTC','YYYY-MM-DD"T"HH:MI:SS"Z"') as polled_at,
            count(distinct(c.id)) as num_channels, array_agg(c.id) as channels
        from github_repos r
            join github_repo_channels rc on (rc.repo_id = r.repo_id)
            join channels c on (c.id = rc.channel_id)
        group by r.repo_id, r.owner_name, r.repo_name, r.polled_at, r.last_pr, r.last_issue
    });

    if ($repos) {
        while ($repos->next) {
            my @notices = $self->get_repo_notices($repos);

            next unless @notices > 0;

            foreach my $channel_id (@{$repos->{'channels'}}) {
                my $channel = RoboBot::Channel->find_by_id($self->bot, $channel_id);
                next unless defined $channel;

                my $response = RoboBot::Response->new(
                    network => $channel->network,
                    channel => $channel,
                    bot     => $bot,
                );

                $response->push(@notices);
                $response->send;
            }
        }
    }

    $self->watcher(
        AnyEvent->timer(
            after => 30,
            cb    => sub { $self->_run_watcher($bot) },
        )
    );
}

__PACKAGE__->meta->make_immutable;

1;
