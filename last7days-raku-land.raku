use v6.d;

use JSON::Fast;
use Shell::Piping;
use DOM::Tiny;
use Zef;
use Zef::Client;
use Zef::Config;

sub infix:<␣>(\l, \r) { l ~ ' ' ~ r }
constant term:<¶> = $?NL;
constant CorruptMetadata = class CorruptMetadata {}.new;

constant CPU-CORES = $*KERNEL.cpu-cores;

my &RED = { "\e[31m$_\e[0m" };
my &BOLD = { "\e[1m$_\e[0m" };

sub qh($s) {
    $s.trans([ '<'   , '>'   , '&' ] =>
             [ '&lt;', '&gt;', '&amp;' ])
}

sub MAIN(Int :$days = 7, Str :$html) {

    my $raku-land = class :: {
        has $.page is rw = 1;
        our $.base = 'https://raku.land';
        method url {
            "$.base/recent?page=$.page"
        }
    }.new;

    my $zero-hour = now.DateTime.truncated-to('day');
    my $last-week-end = $zero-hour.earlier(:days($zero-hour.day-of-week - 1));;
    my $last-week-start = $last-week-end.earlier(:$days);

    with $raku-land {
        # my $zef = Zef::Client.new(config => Zef::Config::parse-file(Zef::Config::guess-path()));
        # my $zef-update = start { $zef.recommendation-manager.update(); }
        
        my $zef;
        my $zef-update  = start { 
            my %opts = (:config(Zef::Config::parse-file(Zef::Config::guess-path())), :update(Bool::True), :error);
            $zef = Zef::Client.new(|%opts);

            with %opts<update> {
                my @plugins = $zef.recommendation-manager.plugins.map(*.Slip).grep(*.defined);

                if %opts<update> === Bool::False {
                    @plugins.map({ try .auto-update = False });
                }
                elsif %opts<update> === Bool::True {
                    @plugins.race(:batch(1)).map(*.?update);
                }
                else {
                    @plugins.grep({.short-name ~~ any(%_<update>.grep(*.not))}).map({ try .auto-update = False });
                    @plugins.grep({.short-name ~~ any(%_<update>.grep(*.so))}).race(:batch(1)).map(*.?update);
                }
            }

            $zef
        };

        note 'start scraping';
        my @raku-land-recent;
        BAIL:
        loop {
            px«curl --silent {.url}» :timeout(60) |» my @response;
            my $root = DOM::Tiny.parse(@response.join(¶));
            for $root.find('main table tr') {
                my ($url, $name, $version, $desc, $datetime, $auth);

                next unless .at('td');

                with .find('td:nth-child(1)')[0] {
                    $url = .at('a')<href>;
                    $name = .at('a').text;
                    $auth = $url.split('/')[1];
                }
                with .find('td:nth-child(2)')[0] {
                    $version = .text;
                }
                with .find('td:nth-child(3)')[0] {
                    $desc = .text;
                }
                with .find('td:nth-child(4)')[0] {
                    $datetime = .at('time')<datetime>.DateTime.truncated-to('day');
                }

                next if $datetime > $last-week-end;
                last BAIL if $datetime < $last-week-start;

                @raku-land-recent.push: %( <date url name auth version desc> Z=> ($datetime.yyyy-mm-dd, $url, $name, $auth, $version, $desc)».chomp».trim );
            }
            .page++;
            $*ERR.print('.');

            die("bailing from scraper loop") if $++ > $days * 100; # sanity check
        }

        note 'done scraping';

        await $zef-update;

        note 'start zeffing';

        # @raku-land-recent = @raku-land-recent.hyper(:1batch, :degree(CPU-CORES)).map: -> $dist {
        @raku-land-recent = @raku-land-recent.map: -> $dist {
            my $qualified = $dist.<name>; # ~ ':auth<' ~ $dist.<auth> ~ '>';
            my @candidates = $zef.search($qualified, :strict);
            $dist<new> = +@candidates == 1 ?? True !! False;
            $dist<author> = @candidates.tail.dist.meta<author authors>.grep(*.defined)[*;*]».trim.join(', ') || $dist.<auth>.split(':').tail;

            $dist<author>.=subst(/ \s* '<' <-[>]>+ '>' /, '', :g);

            $*ERR.print('.');

            $dist;
        }

        note 'done zeffing';

        given $html {

            when 'wordpress' {
                say 'NEW MODULES:';

                for @raku-land-recent.grep(*<new>).classify(*<author>).sort(*.key) -> Pair (:key($author), :value(@dists)) {
                    FIRST put '<ul>';
                    put '<li>';
                    put @dists.sort(*.<name>).squish(:as(*.<url>)).map({ '<a href="' ~ $raku-land.base ~ .<url>.&qh ~ '">' ~ .<name>.&qh ~ '</a>&nbsp;<span>' ~ .<desc>.&qh ~ '</span>' }).join(', ')
                        ~ ¶ ~ ' by <em>' ~ $author ~ '</em>';
                    put '</li>';
                    LAST put '</ul>';
                }

                say 'UPDATES:';

                for @raku-land-recent.grep(!*<new>).classify(*<author>).sort(*.key) -> Pair (:key($author), :value(@dists)) {
                    FIRST put '<ul>';
                    put '<li>';
                    put @dists.sort(*.<name>).squish(:as(*.<url>)).map({ '<a href="' ~ $raku-land.base ~ .<url>.&qh ~ '">' ~ .<name>.&qh ~ '</a>' }).join(', ')
                        ~ ¶ ~ ' by <em>' ~ $author ~ '</em>';
                    put '</li>';
                    LAST put '</ul>';
                }
            }

            default {
                say 'NEW MODULES:';

                for @raku-land-recent.grep(*<new>).classify(*<author>).sort(*.key) -> Pair (:key($author), :value(@dists)) {
                    put @dists.sort(*.<name>).squish(:as(*.<url>)).map({ BOLD(.<name>) ␣ $raku-land.base ~ .<url> }).join(¶) ~ ¶ ~ '    by ' ~ $author
                }

                say 'UPDATES:';

                for @raku-land-recent.grep(!*<new>).classify(*<author>).sort(*.key) -> Pair (:key($author), :value(@dists)) {
                    put @dists.sort(*.<name>).squish(:as(*.<url>)).map({ BOLD(.<name>) ␣ $raku-land.base ~ .<url> }).join(¶) ~ ¶ ~ '    by ' ~ $author
                }
            }
        }
    }
}
