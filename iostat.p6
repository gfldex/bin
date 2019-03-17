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

sub infix:<Z.>(@a, @b){ (@a Z @b).map(-> ($a, &b) { b($a) } ) }

multi sub humanise('') { '' }

multi sub humanise(Numeric $n) {
    my $container = ($n.Int div 921 div 1024) 
    ?? ($n / 1024 / 1024).fmt('%.01fGB')
    !! ($n.Int div 921) 
    ?? ($n / 1024).fmt('%.01fMB') 
    !! $n.fmt('%.fkB');
}

multi sub humanise(Str $s) {
    dd $s;
    exit 1;
}

sub alert(Numeric:D $n, Numeric:D $threshold, Str $postfix --> Str:D) {
    $n >= $threshold 
    ?? RED $n  ~ $postfix 
    !! $n ~ $postfix
}

sub lfill(Cool:D $c, $should-width, $filler = ‚ ‘) {
    my $bare-str = $c.subst(/\e ‚[‘ \d+ ‚m‘/, '', :g);
    $filler x (($should-width - $bare-str.chars) max 0) ~ $c
}

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

constant CRLF = "\x0D\x0A";
constant NL = "\n";
constant TAB = "\t";
constant WS = " ";
constant HTTP-HEADER = ("HTTP/1.1 200 OK", "Content-Type: text/plain; charset=utf-8", "Content-Encoding: UTF-8", "", "").join(CRLF);
constant term:<HTTP-HEADER-404> = ("HTTP/1.1 404 Not Found", "Content-Type: text/plain; charset=UTF-8", "Content-Encoding: UTF-8", "", "").join(CRLF);
constant term:<HTTP-HEADER-501> = ("HTTP/1.1 501 Internal Server Error", "Content-Type: text/plain; charset=utf-8", "Content-Encoding: utf-8", "", "").join(CRLF);

sub MAIN(Int $delay = 0, Str :$bind = '') {
    my $iostat = Proc::Async.new: 'iostat', <-o JSON -x -k>, $delay;
    my $iostat-out = $iostat.stdout;
    my $bcachestat = Proc::Async.new: 'bcachestat', <--json>, $delay;
    my $bcachestat-out = $bcachestat.stdout;

    my %bcache-dirty;
    my @history;
    constant MAX-HISTORY = 1000;

    my $local-addr = $bind.split(':', :skip-empty)[0] // %*ENV<IOSTAT_P6_LISTEN> // ‚localhost‘;
    my $port = $bind.split(':', :skip-empty)[1] // %*ENV<IOSTAT_P6_PORT> // 0;

    react {
        whenever json-stream $iostat-out, [ ['$', **, 'disk' ], ] -> (:$key, :@value) {
            put "" if $++;
            my @table = $[<device read/s write/s util latency dirty>];
            for @value -> %h {
                my ($device, $rkb, $wkb, Num(Any) $util, $r_await, $w_await) = %h<disk_device rkB/s wkB/s util r_await w_await>;
                my $bcache-dirty = %bcache-dirty{$device} // '';
                if $bcache-dirty ~~ /(\d+ '.' \d+) ('G' || 'M' || 'k')/ {
                    $bcache-dirty = $1 eq 'G'
                    ?? $0 * 1024*1024 
                    !! $1 eq 'M' 
                    ?? $0 * 1024
                    !! $0 * 1
                }

                my $await = ($r_await + $w_await) / 2;
                $await.=round($await > 999 ?? 1 !! 0.01);

                @table.push: [$device, $rkb, $wkb, $util, $await, $bcache-dirty];
            }

            @history.push: ((DateTime.now,cached-kb, dirty-kb, writeback-kb), @table[1..*]);
            @history.shift if @history > MAX-HISTORY;

            put ‚cached: ‘, humanise(cached-kb);
            put ‚dirty pages: ‘, humanise(dirty-kb), ‚ writeback: ‘, humanise(writeback-kb);
            put "";

            my $width_0 = max @table[*;0]».chars;
            my @mods = &humanise, &humanise, &alert.assuming(*, 1, ‚%‘), * ~ ‚ms‘, &humanise;
            for @table.head {
                put BOLD [.[0].fmt("% {$width_0}s"), .[1..∞]».fmt("% 8s")];
            }
            for @table[1..*] {
                put [.[0].&lfill($width_0), |.[1..∞].hyper.&infix:<Z.>(@mods)».&lfill(8)];
            }
        }
        whenever json-stream $bcachestat-out, [ ['$', *, *], ] -> (:$key, :%value) {
            for %value -> (:$key, :$value ) {
                next unless $key ~~ /bcache \d+/;
                %bcache-dirty{$key} = $value{'dirty data'};
                # dd %bcache, $value;
            }
        }
        whenever $iostat-out.Promise {
            done;
        }
        whenever signal(SIGINT, SIGTERM, SIGQUIT) {
            $iostat.kill(SIGINT);
            $bcachestat.kill(SIGINT);
            $*OUT.close;

            # dd humanise(max @history[*;1][*;*;5]».Rat);
            done;
        }

        my $sock = do whenever IO::Socket::Async.listen($local-addr, $port) -> $conn {
            start react {
                # with $conn { note BOLD [.peer-host, .peer-port] };

                whenever $conn.Supply.lines {
                    if .head ~~ /^GET <ws> (<[\w„/.=\-“]>+) [„HTTP“ \d „/“ \d]? / {
                        given $0.Str {
                            when ‚/‘ {
                                $conn.print: HTTP-HEADER;
                                for @history -> @record {
                                    my @ram = @record[0];
                                    my @devices = @record[1];
                                    $conn.print: ( @ram[0], |(<cached: dirty pages: writeback:> Z @ram[1..∞]».&humanise) ).join(WS) ~ NL;

                                    my $width_0 = max @devices[*;0]».chars;
                                    my @mods = &humanise, &humanise, * ~ ‚%‘, * ~ ‚ms‘, &humanise;
                                    for @devices {
                                        $conn.print: [.[0].&lfill($width_0), |.[1..∞].hyper.&infix:<Z.>(@mods)».&lfill(8)] ~ NL;
                                    }

                                    $conn.print: NL;
                                }
                                $conn.close;
                                done;
                            }
                            when ‚/tab‘ {
                                $conn.print: HTTP-HEADER;
                                for @history -> $line {
                                    $conn.print: $line[*;*]».join(TAB).join(TAB) ~ NL;
                                }
                                $conn.close;
                                done;
                            }
                            default {
                                $conn.print: HTTP-HEADER-404;
                                $conn.print: „Resource {.Str} not found. Supported resources: / /tab“;
                                $conn.close;
                                done;
                            }
                        }
                    }

                    CATCH {
                        default {
                            $conn.print: HTTP-HEADER-501;
                            $conn.print: ‚501 Internal Server Error‘ ~ NL ~ NL;
                            $conn.print: .^name ~ ': ' ~ .Str ~ NL ~ .backtrace;
                            $conn.close;
                            done;
                        } 
                    }
                }
                whenever Promise.in(60) {
                    $conn.close;
                    done;
                }
            }
        };

        note „listen on port {$sock.socket-port.result}“ unless $sock.socket-port.result;
        $iostat.start;
        $bcachestat.start;
    }

}

