#! /usr/bin/env raku

use v6.d;
# use META6::bin :HELPER;
use Proc::Async::Timeout;
use JSON::Fast;
use Data::Dump::Tree;

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

my %distros-old;
my %distros-young;

my $zero-hour = now.DateTime.truncated-to('day');
my $monday-young = $zero-hour.earlier(:days($zero-hour.day-of-week - 1));
my $monday-old = $monday-young.earlier(:7days);

my @ecosystems-commits = github-get-remote-commits(‚ugexe‘, ‚Perl6-ecosystems‘, :since($monday-old), :until($monday-young));

my ($youngest-commit, $oldest-commit) = @ecosystems-commits[0,*-1]».<sha>;

my @ecosystems-old = fetch-ecosystem(:commit($oldest-commit));
.&normalize-meta6 for @ecosystems-old;
my @nameversions-old = @ecosystems-old.sort(*.<name>).map: { .<name> ~ ' ' ~ .<version> ~ ' https://modules.raku.org/search/?q=' ~ .<name> };


# spurt("%*ENV<HOME>/tmp/ecosystem-{$monday-old.yyyy-mm-dd}.txt", @nameversions-old.join($?NL));

my @ecosystems-young = fetch-ecosystem(:commit($youngest-commit));
.&normalize-meta6 for @ecosystems-young;
my @nameversions-young = @ecosystems-young.sort(*.<name>).map: { .<name> ~ ' ' ~ .<version> ~ ' https://modules.raku.org/search/?q=' ~ .<name> };

# spurt("%*ENV<HOME>/tmp/ecosystem-{$monday-young.yyyy-mm-dd}.txt", @nameversions-young.join($?NL));

our $new-versions-last-week is export = @nameversions-young ∖ @nameversions-old;

sub MAIN {
    .say for $new-versions-last-week.keys;
}

sub normalize-meta6($_ is raw) is rw {
    if none(.<source-url>, .<support><source>) {
        # say 'bailing on:';
        # .&ddt;
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

    if ! all(.<name>, .<auth>, .<version>) {
        say 'bailing on';
        .&ddt;
    }
}
