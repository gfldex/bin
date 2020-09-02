#! /usr/bin/env raku

use v6.d;

use JSON::Fast;
use Data::Dump::Tree;
use Shell::Piping;

constant term:<␣> = ' ';
constant term:<¶> = $?NL;

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
    @response.flat
}

my %distros;

my $zero-hour = now.DateTime.truncated-to('day');
my $monday-young = $zero-hour.earlier(:days($zero-hour.day-of-week - 1));
my $monday-old = $monday-young.earlier(:7days);

my @ecosystems-commits = github-get-remote-commits(‚ugexe‘, ‚Perl6-ecosystems‘, :since($monday-old), :until($monday-young));

my ($youngest-commit, $oldest-commit) = @ecosystems-commits[0,*-1]».<sha>;

my @ecosystems-old = fetch-ecosystem(:commit($oldest-commit));
.&normalize-meta6 for @ecosystems-old;
my @nameversions-old = @ecosystems-old.sort(*.<name>).map: { 
    my $key = .<name> ~ ' ' ~ .<version>;
    %distros{$key} = $_;
    $key
};

# spurt("%*ENV<HOME>/tmp/ecosystem-{$monday-old.yyyy-mm-dd}.txt", @nameversions-old.join(¶));

my @ecosystems-young = fetch-ecosystem(:commit($youngest-commit));
.&normalize-meta6 for @ecosystems-young;
my @nameversions-young = @ecosystems-young.sort(*.<name>).map: { 
    my $key = .<name> ~ ' ' ~ .<version>;
    %distros{$key} = $_;
    $key
};

# spurt("%*ENV<HOME>/tmp/ecosystem-{$monday-young.yyyy-mm-dd}.txt", @nameversions-young.join(¶));

our $new-versions-last-week is export = @nameversions-young ∖ @nameversions-old;

sub MAIN(:v(:$verbose)) {
    my $*verbose = $verbose;

    for %distros{$new-versions-last-week.keys}.sort({.<authors> // .<author> // .<auth>}) {
        warn ‚WARN: no auth field in META6.json.‘ unless .<auth>;
        $_ = fetch-cpan-meta6(.<source-url>, .<auth>) if .<auth>.starts-with('cpan:'); 

        if .<auth>.starts-with('github:') && !.<author> && !.<authors> {
            .<author> = github-realname(.<auth>.split(':')[1]);
        }

        .<new-module> = @ecosystems-old.grep(*.<name> eq .<name>).head.<version> ?? '' !! 'NEW MODULE';

        put .<name> ~ ␣ ~ .<version> ~ ␣ ~ .<auth> ~ ␣ ~ .<new-module>;
            put ('https://modules.raku.org/search/?q=' ~ .<name>).indent(4);
            put (.<source-url> // .<support><source>).indent(4);
            put (.<authors> // .<author> // .<auth>)».?indent(4).join(';');
    }
}

sub fetch-cpan-meta6($source-url, $auth) {
    my @meta6;
    px«curl -s $source-url» |» px<tar -xz -O --no-wildcards-match-slash --wildcards */META6.json> |» @meta6;

    my $meta6 = @meta6.join.chomp.&from-json;
    $meta6.<auth> = $auth unless $meta6.<auth>;

    $meta6;
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
        say 'bailing on';
        .&ddt;
    }
}
