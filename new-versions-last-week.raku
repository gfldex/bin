#! /usr/bin/env raku

use v6.d;

use JSON::Fast;
use Shell::Piping;

constant term:<␣> = ' ';
constant term:<¶> = $?NL;
constant CorruptMetadata = class CorruptMetadata {}.new;

constant CPU-CORES = $*KERNEL.cpu-cores;

my &RED = { "\e[31m$_\e[0m" };
my &BOLD = { "\e[1m$_\e[0m" };

sub qh($s) {
    $s.trans([ '<'   , '>'   , '&' ] =>
             [ '&lt;', '&gt;', '&amp;' ])
}

my $timeout = 60;

sub fetch-ecosystem(:$verbose, :$cached, :$commit) {
    state $cache;
    return $cache.Slip if $cached && $cache.defined;

    my $p6c-org-url = $commit ?? „https://raw.githubusercontent.com/ugexe/Perl6-ecosystems/$commit/p6c.json“ !! 'https://raw.githubusercontent.com/ugexe/Perl6-ecosystems/master/p6c.json';

    my $p6c-org = Proc::Async.new('curl', '--silent', $p6c-org-url);
    my Promise $p1;
    my $p6c-response;
    $p6c-org.stdout.tap: { $p6c-response ~= .Str };

    my $cpan-org-url = $commit ?? „https://raw.githubusercontent.com/ugexe/Perl6-ecosystems/$commit/cpan.json“ !! 'https://raw.githubusercontent.com/ugexe/Perl6-ecosystems/master/cpan.json';

    my $cpan-org = Proc::Async.new('curl', '--silent', $cpan-org-url);
    my Promise $p2;
    my $cpan-response;
    $cpan-org.stdout.tap: { $cpan-response ~= .Str };

    note "Fetching module list." if $verbose;
    await Promise.anyof(Promise.allof(($p1 = $p6c-org.start), ($p2 = $cpan-org.start)), Promise.at(now + $timeout));
    fail "⟨curl⟩ timed out." if $p1.status|$p2.status == Broken;
    
    note "Parsing module list." if $verbose;
    $cache = flat
        from-json($p6c-response).flat.cache,
        from-json($cpan-response).flat.cache;
    
    $cache.Slip
}

sub github-get-remote-commits($owner, $repo, :$since, :$until) is export(:GIT) {
    my $cache-file = $*TMPDIR.add('thatwasthemodulethatwas-remote-commits.cache');
    if $*cached && $cache-file.f {
        if now - $cache-file.modified < 30 * 60 {
            warn ‚reading cache‘;
            return $cache-file.slurp.&from-json;
        }
    }
    my $page = 1;
    my @response;
    loop {
        my $commits-url = $since && $until ?? „https://api.github.com/repos/$owner/$repo/commits?since=$since&until=$until&per_page=100&page=$page“ !! „https://api.github.com/repos/$owner/$repo/commits“;
        my $curl = Proc::Async::Timeout.new('curl', '--silent', '-X', 'GET', $commits-url);
        my $github-response;
        $curl.stdout.tap: { $github-response ~= .Str };

        await my $p = $curl.start: :$timeout;
        @response.append: from-json($github-response);

        last unless from-json($github-response)[0].<commit>;
        $page++;
    }
    
    if @response.flat.grep(*.<message>) && @response.flat.hash.<message>.starts-with('API rate limit exceeded') {
        die „github hourly rate limit hit.“;
    }

    if $*cached {
        $cache-file.spurt(@response.flat.&to-json);
    }

    @response.flat
}

sub fetch-distros(DateTime:D $old, DateTime:D $young) {
    my %distros;
    my @ecosystems-commits = github-get-remote-commits(‚ugexe‘, ‚Perl6-ecosystems‘, :since($old), :until($young));

    my ($youngest-commit, $oldest-commit) = @ecosystems-commits[0,*-1]».<sha>;

    my @ecosystems-old = fetch-ecosystem(:commit($oldest-commit)).grep(*.<perl>.?starts-with('6'));
    .&normalize-meta6 for @ecosystems-old;
    my @nameversions-old = @ecosystems-old.sort(*.<name>).map: { 
        my $key = .<name> ~ ' ' ~ .<version>;
        %distros{$key} = $_;
        $key
    };

# spurt("%*ENV<HOME>/tmp/ecosystem-{$monday-old.yyyy-mm-dd}.txt", @nameversions-old.join(¶));

    my @ecosystems-young = fetch-ecosystem(:commit($youngest-commit)).grep(*.<perl>.?starts-with('6'));
    .&normalize-meta6 for @ecosystems-young;
    my @nameversions-young = @ecosystems-young.sort(*.<name>).map: { 
        my $key = .<name> ~ ' ' ~ .<version>;
        %distros{$key} = $_;
        $key
    };

# spurt("%*ENV<HOME>/tmp/ecosystem-{$monday-young.yyyy-mm-dd}.txt", @nameversions-young.join(¶));

    my $new-versions = @nameversions-young ∖ @nameversions-old;

    %distros{$new-versions.keys}.race(:batch(4), :degree(CPU-CORES)).map( <-> $_ {
        next unless .<perl>.?starts-with('6');

        $*ERR.print('.') if $*verbose;

        # $_ = fetch-cpan-meta6(.<source-url>, .<auth>) if .<auth>.starts-with('cpan:'); 
        # try { $_ = fetch-cpan-meta6(.<source-url>, .<auth>) if (.<source-url> // .<support><source>).contains('www.cpan.org'); } or die $_;
        $_ = fetch-cpan-meta6(.<source-url>, .<auth>) if (.<source-url> // .<support><source>).?contains('www.cpan.org');
        
        if .<auth>.starts-with('github:') && !.<author> && !.<authors> {
            .<author> = github-realname(.<auth>.split(':')[1]);
        }
        
        .<new-module> = @ecosystems-old.grep(*.<name> eq .<name>).head.<version> ?? False !! True;
    });

    %distros, $new-versions.keys
}

multi sub MAIN(Bool :v(:$verbose), Str :$html, Bool :w(:$weekly) = True, Bool :$last7days, Bool :$last30days, Int :$year) {
    my $*verbose = $verbose;

    my $*cached = False;

    my ($old, $young);
    if $weekly {
        # monday 00:00 this week until monday 00:00 last week
        my $zero-hour = now.DateTime.truncated-to('day');
        $young = $zero-hour.earlier(:days($zero-hour.day-of-week - 1));
        # $young = DateTime.new(2020, 9, 7, 0, 0, 0);
        $old = $young.earlier(:7days);
    }

    if $last7days {
        $young = now.DateTime;
        $old = $young.earlier(:7days);
    }

    if $last30days {
        $young = now.DateTime;
        $old = $young.earlier(:30days);
    }

    if $year {
        $old = DateTime.new($year, 1, 1, 0, 0, 0);
        $young = DateTime.new($year, 12, 31, 23, 59, 59);
    }

    my (%distros, @new-versions) := fetch-distros($old, $young);

    if $html ~~ 'wordpress' {
        put BOLD ‚new modules:‘;
        for %distros{@new-versions}.grep(*.<new-module>).sort({.<authors> // .<author> // .<auth>}) {
            FIRST put '<ul>';

            put '<li>';
            put '<a href="' ~ 'https://modules.raku.org/dist/' ~ .<name> ~ '">' ~ .<name> ~ '</a> by <em>' 
                ~ (.<authors> // .<author> // .<auth>).join('; ').&qh ~ '</em>.';
            put '</li>';

            LAST put '</ul>';
        }
    
        put BOLD ‚updated modules:‘;
        for %distros{@new-versions}.grep(!*.<new-module>).sort({.<authors> // .<author> // .<auth>}) {
            FIRST put '<ul>';

            put '<li>';
            put '<a href="' ~ 'https://modules.raku.org/dist/' ~ .<name> ~ '">' ~ .<name> ~ '</a> by <em>' 
                ~ (.<authors> // .<author> // .<auth>).join('; ').&qh ~ '</em>.';
            put '</li>';

            LAST put '</ul>';
        }
    } else {
        for %distros{@new-versions}.grep(*.<new-module>).sort({.<authors> // .<author> // .<auth>}) {
            once put BOLD ‚new modules:‘;

            put .<name> ~ ␣ ~ .<version> ~ ␣ ~ .<auth>;
                put ('https://modules.raku.org/dist/' ~ .<name>).indent(4);
                put (.<source-url> // .<support><source>).?indent(4) // "<no-source-url-provided>";
                put (.<authors> // .<author> // .<auth>).join('; ').indent(4);
        }

        for %distros{@new-versions}.grep(!*.<new-module>).sort({.<authors> // .<author> // .<auth>}) {
            once put BOLD ‚updated modules:‘;

            put .<name> ~ ␣ ~ .<version> ~ ␣ ~ .<auth>;
                put ('https://modules.raku.org/dist/' ~ .<name>).indent(4);
                put (.<source-url> // .<support><source>).?indent(4) // "<no-source-url-provided>";
                put (.<authors> // .<author> // .<auth>).join('; ').indent(4);
        }
    }
}

sub fetch-cpan-meta6($source-url, $auth) {
    CATCH {
        when X::Shell::NonZeroExitcode {
            put RED „Fetching META6.json for $source-url failed“;
            return CorruptMetadata;
        }
        default { say .^name, ': ', .message }
    }
    note „fetching cpan distro $source-url“ if $*verbose;
    state $TAR-IS-GNU;

    without $TAR-IS-GNU {
        my @tar;
        px<tar --version> |» @tar;
        $TAR-IS-GNU = @tar».contains('(GNU tar)').any.so;
    }

    my @meta6;
    if $TAR-IS-GNU {
        px«curl -s $source-url» |» px<tar -xz -O --no-wildcards-match-slash --wildcards */META6.json> |» @meta6;
    } else {
        my @files;
        px«curl -s $source-url» |» px<tar --list -z> |» @files;
        my $meta6-path = @files».split('/').grep({ .[1] ~~ 'META6.json'}).head.join('/');

        px«curl -s $source-url» |» px«tar -xz -O $meta6-path» |» @meta6;
    }

    my $meta6 = @meta6.join.chomp.&from-json;
    $meta6.<auth> = $auth unless $meta6.<auth>;

    $meta6
}

sub github-realname(Str:D $handle) {
    my @github-response;

    my $url = 'https://api.github.com/users:' ~ $handle;
    px«curl -s -X GET $url» |» @github-response;

    @github-response.join.&from-json.<name>
}

sub normalize-meta6($_ is raw) is rw {
    if none(.<source-url>, .<support><source>) {
        next;
    }
    .<source-url> := .<support><source> unless .<source-url>;

    if .<source-url>.contains('//www.cpan.org') {
        .<auth> = 'cpan:' ~ .<source-url>.split('/')[7];
    } elsif none(.<auth>) && .<source-url>.contains('//github.com') {
        .<auth> = 'github:' ~ .<source-url>.split('/')[3];
    } elsif none(.<auth>) && .<source-url>.contains('//gitlab.com') {
        .<auth> = 'gitlab:' ~ .<source-url>.split('/')[3];
    } elsif none(.<auth>) && .<source-url>.contains('git@github.com') {
        .<auth> = 'github:' ~ .<source-url>.split(</ :>)[1];
    }

    if $*verbose && ! all(.<name>, .<auth>, .<version>) {
        note 'bailing on';
        note .&to-json;
    }
}
