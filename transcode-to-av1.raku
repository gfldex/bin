#! /usr/bin/env raku

use v6.d;

use Shell::Piping;

# INPUT=$1
# OUTPUT=${INPUT%.*}.av1.mkv
# TMPDIR=$(basename $(mktemp -u))
# BITRATE=1000K && [[ $2 != "" ]] && BITRATE=$2
# # mkdir $TMPDIR
# # cd $TMPDIR
# 
# LD_LIBRARY_PATH+=":/usr/local/lib" nice /usr/local/bin/ffmpeg -i "./$INPUT" -c:v libsvt_av1 -q 30 -sc_detection 1 -forced-idr 1 -y "./$OUTPUT"
# 
# say "transcoding finished" &
# 
# 
# # cd ..
# # rm $TMPDIR/*
# # rmdir $TMPDIR

multi sub MAIN(*@input, Bool :$verbose) {
    exit 0 unless @input;

    my $input = @input.join(' ');
    my $output = $input.IO.extension('av1.mkv');
    say $input, ' => ', $output.basename;

    my $ffmpeg-out = Channel.new;
    my $ffmpeg-err = Channel.new;

    start {
        my $video-duration;
        my $encoding-started-at;
        react {
            whenever $ffmpeg-err -> [ $stream-num, $_ ] {
                .say if $verbose;
                # Duration: 01:32:22.05, start: 0.000000, bitrate: 6551 kb/s
                if / 'Duration: ' (\d\d) ':' (\d\d) ':' (\d\d) '.' (\d\d) ',' / {
                    my $duration = Duration.new($0 * 60 * 60 + $1 * 60 + $2 + $3 / 100);
                    $video-duration = [max] $video-duration, $duration;
                    $encoding-started-at = now;
                }

                # frame=  203 fps= 11 q=28.0 size=     273kB time=00:00:03.64 bitrate= 614.2kbits/s speed=0.189x

                if / 'time=' (\d\d) ':' (\d\d) ':' (\d\d) '.' (\d\d) \s+ 'bitrate=' \s* (<-[\s]>+) \s / {
                    my $time-index = Duration.new($0 * 60 * 60 + $1 * 60 + $2 + $3 / 100);
                    my $bitrate = $4;
                    my $elapsed = now - $encoding-started-at;
                    my $remaining-time = $video-duration - $time-index;
                    my $speed = $time-index / $elapsed;
                    my $ETA = (now + $remaining-time / $speed).DateTime;
                    print "\r", ($time-index / $video-duration * 100).fmt('%.2f%% ETA: '), { slip .dd-mm-yyyy, .hh-mm-ss }($ETA.local), ‚   ‘ ,$bitrate;
                }
            }
            whenever $ffmpeg-out {
                say "$_";
            }
        }
    }

    %*ENV<LD_LIBRARY_PATH> ~= ':/usr/local/lib';
    # px{'nice', '/usr/local/bin/ffmpeg', '-i', $input, '-c:v', 'libsvt_av1', '-q', '30', '-sc_detection', '1', '-forced-idr', '1', '-y', $output} |» $ffmpeg-out :stderr($ffmpeg-err);
    
    px{'nice', '/usr/local/bin/ffmpeg', '-i', $input, '-c:v', 'libsvtav1', '-q', '60', '-preset', '5', '-y', $output} |» $ffmpeg-out :stderr($ffmpeg-err);
    # px{'/usr/bin/ffmpeg', '-i', $input, '-c:v', 'libaom-av1', '-crf', '20', '-b:v', '0', '-strict', 'experimental', '-cpu-used', '1', '-row-mt', '1', '-tiles', '2x2',  '-y', $output} |» $ffmpeg-out :stderr($ffmpeg-err);
 

    print "\n";
    
    px{'stat', '-t', $input} |» my @stat;
    my $birth-time = DateTime.new(@stat[0].split(' ').reverse[1].Int);
    px{'touch', '-d', $birth-time, $output};
}
