#!/usr/bin/perl -CS

use strict;
use warnings;

use Encode;
use Getopt::Long;

{
    package RssToPHPBB;

    use Date::Parse qw(str2time);
    use LWP::UserAgent;
    use HTTP::Cookies;
    use XML::RSS;

    use constant {
        APP_NAME    =>  'RssBB Poster',
        APP_VERS    =>  '1.2',
        APP_HOME    =>  'http://linuxhub.ru',
        INIT_KEYS   =>  [ 'f_url', 'f_login', 'f_pass', 'f_post_id', 'f_post_subj', 'save_file',
                          'f_post_label', 'rss_url', 'debug', 'errors_handler', 'debug_handler' ],
        POST_TRIES  =>  3,
        TIMEOUT     =>  180,
        F_LOGIN_PATH    => 'ucp.php?mode=login',
        F_NEW_TOPIC     => 'posting.php?mode=post&f=',
        MIN_NEWS_COUNT  => 3,
    };

    our @data = ();
    our $cookies = HTTP::Cookies->new();
    our $digest_number = 0;
    our $has_errors    = 0;
    our $last_update   = '';

    sub new {
        my $class = shift;
        my %args = @_;
        my $self = {};

        for my $key ( @{INIT_KEYS()} ) {
            $self->{$key} = $args{$key} if $args{$key};
        }

        $self->{ua} = LWP::UserAgent->new(
            timeout => TIMEOUT,
            agent   => 'Mozilla/5.0 (compatible; ' . APP_NAME . '/' . APP_VERS . '; +' . APP_HOME . ')',
        );
        $self->{ua}->cookie_jar($cookies);

        bless $self, $class;
        return $self;
    }

    sub _debug {
        my $self = shift;
        return unless $self->{debug};

        if ( ref $self->{debug_handler} eq 'CODE' ) {
            $self->{debug_handler}->(@_);
            return;
        }

        print STDERR "[debug] @_\n" if $self->{debug};
    }

    sub _error {
        my $self = shift;
        $has_errors++;

        if ( ref $self->{errors_handler} eq 'CODE' ) {
            $self->{errors_handler}->(@_);
            return;
        }

        print STDERR "[error] @_\n";
    }

    sub load {
        my $self = shift;

        $self->_debug( "Load last digest info from file: $self->{save_file}" );
        if ( open( FH, "<", $self->{save_file} ) ) {
            my $cnt = 0;
            while ( <FH> ) {
                chomp;
                $digest_number = $_ if $cnt == 0;
                $last_update   = $_ if $cnt == 1;
                $cnt++;
                last if ( $cnt > 1 );
            }
            close( FH );

            $self->_debug( "Previous digest number: $digest_number" ) if $digest_number;
            $self->_debug( "Previous date of update: $last_update" ) if $last_update;
        }

        $self->_debug( "Load RSS Feed from: $self->{rss_url}" );
        my $response = $self->{ua}->get( $self->{rss_url} );

        unless ( $response->is_success() ) {
            $self->_error( "Cannot load RSS Feed" );
            return $self;
        }

        my $content = $response->content();
        my $rss = XML::RSS->new();
        $rss->parse( $content );
        push( @data, @{$rss->{items}} );

        $self->_debug( "Found " . scalar( @data ) . " item(s) in the RSS Feed" );

        return $self;
    }

    sub save {
        my $self = shift;
        return if $has_errors;

        $self->_debug( "Save digest info to file: $self->{save_file}" );

        if ( open( FH, '>', $self->{save_file} ) ) {
            binmode( FH );
            print FH "$digest_number\n";
            print FH "$last_update\n";
            close( FH );
        } else {
            $self->_error( "Can't save digest info: $!" );
        }
    }

    sub do_work {
        my $self = shift;

        # Build all feeds in post_msg
        my $post_msg = "";

        my $count_of_new_news = 0;
        my $m_last_update;
        for my $item( reverse( @data ) ) {
            if ( !$last_update || ( $last_update && str2time( $item->{pubDate} ) > str2time( $last_update ) ) ) {
                # FIXME: Dirty hack to fix numeric entities after double encoding feed on server side
                $item->{title} =~ s/&#(\d+);/chr($1)/ge;
                $item->{description} =~ s/&#(\d+);/chr($1)/ge;

                $self->_debug( "New item found: '$item->{title}'" );
                $post_msg .= "[b]" . $item->{title} . "[/b]\n";
                $post_msg .= $item->{'description'} . "\n";
                $post_msg .= "[url=" . $item->{link} . "]" .$self->{f_post_label} . "[/url]";
                $post_msg .= "\n\n\n";
                $count_of_new_news++;
                $m_last_update = $item->{'pubDate'};
            }
        }

        if ( !$count_of_new_news ) {
            $self->_debug( "Sorry, no news" );
            return;
        } elsif ( $count_of_new_news < MIN_NEWS_COUNT() ) {
            $self->_debug( "Too few items: $count_of_new_news of " . MIN_NEWS_COUNT() );
            return;
        }

        # Bump digest number and last update date
        $digest_number++;
        $last_update = $m_last_update;
        $self->_debug( "$count_of_new_news news ready to post" );


        # START Login into a forum
        my $login_url = join( '/', $self->{f_url}, F_LOGIN_PATH() );
        $self->_debug( "Forum login url: $login_url" );
        my $response = $self->{ua}->post( $login_url,
            {
                username => $self->{f_login},
                password => $self->{f_pass},
                redirect => "index.php",
                login    => 1
            }
        );

        unless ( !$response->content() && $response->headers()->{location} ) {
            $self->_error( "Can't login to forum. Status code: " . $response->code() );
            return;
        }
        # END Login into a forum


        # START Get post message page
        my $create_topic_url = join( '/', $self->{f_url}, F_NEW_TOPIC() . $self->{f_post_id} );
        $self->_debug( "Forum create topic url: $create_topic_url" );

        $self->{ua}->default_header( 'Referer' => $create_topic_url );
        $response = $self->{ua}->get( $create_topic_url );

        unless ( $response->is_success() ) {
            $self->_error( "Can't get posting page. Status code: " . $response->code() );
            return;
        }

        $self->_debug( "Get mandatory data from url: $create_topic_url" );

        my $post_form_content = $response->content();
        my ( $creation_time ) = $post_form_content =~ m/.*name=\"(?:creation_time)\" *value=\"(.*)\".*/gm;
        my ( $form_token ) = $post_form_content =~ m/.*name=\"(?:form_token)\" *value=\"(.*)\".*/gm;

        unless ( $creation_time && $form_token ) {
            $self->_error( "Can't get mandatory data to create new topic" );
            return;
        }

        my $post_subj = $self->{f_post_subj};
        $post_subj =~ s/DIGEST_NUM/$digest_number/;

        my ( $is_sended, $number_of_tries ) = ( undef, POST_TRIES() );
        while ( $number_of_tries > 0 && !$is_sended ) {
            # Send post message to forum
            $response = $self->{ua}->post( $create_topic_url,
                {
                    post              => 1,
                    subject           => $post_subj,
                    message           => $post_msg,
                    creation_time     => $creation_time,
                    form_token        => $form_token,
                }
            );

            if ( !$response->content() && $response->headers()->{location} ) {
                $is_sended = 1;
            } else {
                $self->_debug( "Trying to post news on forum" ) if ( $number_of_tries == POST_TRIES() );
                $self->_debug( $number_of_tries-- . " ... Status code: " . $response->code() );
            }
        }

        $self->_error( "News was not posted on forum" ) unless ( $is_sended );
        # END Get post message page
    }
}

my $forum_url;
my $forum_login;
my $forum_passw;
my $forum_post_id;
my $forum_post_subj = decode( 'utf8', 'Дайджест новостей № DIGEST_NUM' );
my $forum_post_label = decode( 'utf8', '[Подробнее]' );
my $save_file = '/tmp/rss.save';
my $rss_url = 'http://www.opennet.ru/opennews/opennews_all_noadv.rss';
my $debug;

sub usage {
    print STDERR "Usage: $0 [ARGS]\n\n";
    print STDERR "Mandatory arguments:\n";
    print STDERR "\t--forum-url='http://linuxhub.ru'\n";
    print STDERR "\t--forum-login='TestUser'\n";
    print STDERR "\t--forum-passw='TestPassword'\n";
    print STDERR "\t--forum-post-id=7\n\n";
    print STDERR "Optional arguments:\n";
    print STDERR "\t--forum-post-subj='$forum_post_subj'\n";
    print STDERR "\t--forum-post-label='$forum_post_label'\n";
    print STDERR "\t--save-file='$save_file'\n";
    print STDERR "\t--rss-url='$rss_url'\n";
    print STDERR "\t--debug\n";
}

my $help = 0;

GetOptions(
    "help"      => \$help,
    "debug"     => \$debug,
    "rss-url=s" => \$rss_url,
    "save-file=s"   => \$save_file,
    "forum-url=s"   => \$forum_url,
    "forum-login=s" => \$forum_login,
    "forum-passw=s" => \$forum_passw,
    "forum-post-id=i"    => \$forum_post_id,
    "forum-post-subj=s"  => \$forum_post_subj,
    "forum-post-label=s" => \$forum_post_label,
) or usage() and die( "Error in command line arguments\n" );

$help = 1 unless ($forum_url && $forum_login && $forum_passw && $forum_post_id);
usage() and exit(0) if $help;

my $poster = RssToPHPBB->new(
    f_url          => $forum_url,
    f_login        => $forum_login,
    f_pass         => $forum_passw,
    f_post_id      => $forum_post_id,
    f_post_subj    => $forum_post_subj,
    f_post_label   => $forum_post_label,
    save_file      => $save_file,
    rss_url        => $rss_url,
    debug          => $debug,
    errors_handler => sub { print STDERR "[error] @_\n"; },
    debug_handler  => sub { return unless ($debug); print STDERR "[debug] @_\n"; },
);

$poster->load();
$poster->do_work();
$poster->save();

exit(0);

