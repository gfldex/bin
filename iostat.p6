#! /usr/bin/env perl6
use v6.c;

use JSON::Stream;

my &BOLD = sub (**@s) {
    "\e[1m{@s.join('')}\e[0m"
}

my &RED = sub (**@s) {
    "\e[31m{@s.join('')}\e[0m"
}

my &RESET = sub (**@s) {
    "\e[0m{@s.join('')}\e[0m"
}

my &BG-RED = sub (**@s) {
    "\e[41m{@s.join('')}\e[0m";
}

&BOLD = &RED = &RESET = sub (Stringy $s) { $s } unless $*OUT.t;

role Width[$w] { has $.width = $w }
multi sub add-width(Width \s) { \s }
multi sub add-width(Cool $s is copy) { $s = $s but Width[$s.chars] }
multi sub add-width(Cool $s is copy, $real-width) { $s = $s but Width[$real-width] }

# sub lfill($c, $should-width, $filler = ‚ ‘) { $filler x (($should-width - $c.width) max 0) ~ $c }

sub humanise(Numeric $n) {
    my $container = ($n.Int div 921 div 1024) 
    ?? ($n / 1024 / 1024).fmt('%.01fGB')
    !! ($n.Int div 921) 
        ?? ($n / 1024).fmt('%.01fMB') 
        !! $n.fmt('%.fkB');
   
   add-width($container) # segfault MARK
}

sub lfill(Cool:D $c, $should-width, $filler = ‚ ‘) {
    my $bare-str = $c.subst(/\e ‚[‘ \d+ ‚m‘/, '', :g);
    $filler x (($should-width - $bare-str.chars) max 0) ~ $c
}

# say trans-lfill(RED(‚foo‘), 8);

sub dirty-kb() {
    slurp('/proc/meminfo').lines.grep(*.starts-with(‚Dirty:‘)) ~~ /‚Dirty:‘ \s+ (\d+) \s ‚kB‘/;
    $0.Numeric
}

sub cached-kb() {
    slurp('/proc/meminfo').lines.grep(*.starts-with(‚Cached:‘)) ~~ /‚Cached:‘ \s+ (\d+) \s ‚kB‘/;
    $0.Numeric
}

sub writeback-kb() {
    slurp('/proc/meminfo').lines.grep(*.starts-with(‚Writeback:‘)) ~~ /‚Writeback:‘ \s+ (\d+) \s ‚kB‘/;
    $0.Numeric
}

sub MAIN(Int $delay = 0) {
    my $iostat = Proc::Async.new: 'iostat', <-o JSON -x -k>, $delay;
    my $iostat-out = $iostat.stdout;
    react {
        whenever json-stream $iostat-out, [ ['$', **, 'disk' ], ] -> (:$key, :@value) {
            put "" if $++;
            my @table = $[<device read/s write/s util latency>];
            for @value -> %h {
                my ($device, $rkb, $wkb, Num(Any) $util, $r_await, $w_await) = %h<disk_device rkB/s wkB/s util r_await w_await>;

                my $await = ($r_await + $w_await) / 2;
                $await.=round($await > 999 ?? 1 !! 0.01);

                $util = ($util > 90) ?? RED($util ~ '%') !! $util ~ '%';
                
                @table.push: [$device, humanise($rkb), humanise($wkb), $util, $await ~ 'ms'];
            }
            my $width_0 = max @table[*;0]».chars;
            put ‚cached: ‘, humanise(cached-kb);
            put ‚dirty pages: ‘, humanise(dirty-kb), ‚ writeback: ‘, humanise(writeback-kb);
            put "";
            for @table {
                if $++ {
                    my @fields = [.[0].&lfill($width_0), |.[1..∞]».&lfill(8)];
                    put @fields;
                } else { 
                    put BOLD [.[0].fmt("% {$width_0}s"), .[1..∞]».fmt("% 8s")];
                }
            }
        }
        whenever $iostat-out.Promise {
            done;
        }
        whenever signal(SIGTERM, SIGQUIT) {
            $iostat.kill(SIGINT);
            done;
        }
        $iostat.start;
    }
}

