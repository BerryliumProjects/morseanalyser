#! /usr/bin/perl

# parameter default values
$targetwpm = 15;
$amplefile = undef;
$seconds = 30;

if ($ARGV[0] > 4) {
    $targetwpm = $ARGV[0];
}

if ($ARGV[1] > 5) {
   $seconds = $ARGV[1];
} elsif (-f $ARGV[1]) {
   $samplefile = $ARGV[1];
}

$samplingrate = 8000; # should be a multiple of 1000
$startdelay = 3; # seconds
$startdelaysamples = $startdelay * $samplingrate;

@intensity = ();

%histogram; # hash of arrays
$histogramwidth = 10;
$targetdit = int(1200 / $targetwpm);
$maxdit = $targetdit * 2;
$maxchargap = $targetdit * 5.5;

print "Using $targetwpm wpm, dit is $targetdit ms. Splitting at $maxdit and $maxchargap ms.\n";

CollectSample();
DetectIntensity(); # get tone intensity each millisecond

print "@intensity\n"; 

RecogniseElements();

# show histogram stats

$meandot = ReportHistogram('Dot');
$meandash = ReportHistogram('Dash');
$meanegap = ReportHistogram('Element Gap');
$meancgap = ReportHistogram('Character Gap');
$meanwgap = ReportHistogram('Word Gap');
SummarizeSample();
ReplaySample();

sub CollectSample {
    unless (defined $samplefile) {
        $samplefile = '/var/tmp/morseanalyser.raw';
        print "Sampling starts after ${startdelay}s for ${seconds}s, or until Ctrl+C\n";
        system qq{arecord -t raw -f U8 -r $samplingrate -d $seconds $samplefile};
    }

    open (AU, $samplefile) or
        die "Can't find $samplefile";

    binmode(AU);
    seek(AU, $startdelaysamples, 0); # ignore initial settling period

    if (eof(AU)) {
        die "Sample is shorter than start delay\n";
    }

    $/ = undef;    

    $rawaudio = <AU>; # whole file

    close(AU);

    $/ = "\n";

    @datavalues = unpack('C*', $rawaudio);
}

sub DetectIntensity {
    $tonefrequency = 1000;
    $runningsum = 0;
    $runninglength = int(0.5 + $samplingrate / $tonefrequency * 2);
    $smoothingtimems = 5;
    $intensitylength = $samplingrate / 1000 * $smoothingtimems;
    $newintensityweight = 1 / $intensitylength;
    $accintensityweight = 1 - $newintensityweight;
    $samplespermillisecond = int($samplingrate / 1000 + 0.5);

    foreach $i (0 .. $runninglength - 1) {
	$runningsum += $datavalues[$i];
    }

    foreach $i ($runninglength .. @datavalues - 1) {
        $data1 = $datavalues[$i] - int($runningsum / $runninglength);
        $runningsum += ($datavalues[$i] - $datavalues[$i - $runninglength]);
        $intensity = ($data1 > 0 ? $data1 : -$data1);

        $smoothedintensity = $smoothedintensity * $accintensityweight + 
            $intensity * $newintensityweight;

        if (($i + 1) % $samplespermillisecond == 0) { # if final sample in millisecond
            push(@intensity, int(0.5+$smoothedintensity));
        }
    }
} 

sub RecogniseElements {
    $noisefloor = 2;
    $waitingtostart = 1;
    $msdurthreshold = 20; # 20 ms
    $markspaceduration = 0;
    $mark = 0;
    $cumulativemarkintensity = 0;
    $averagemarkintensity = 0;
    $markcount = 0;

    foreach $i (0 .. @intensity - 1) {
        if ($intensity[$i] > $noisefloor) {
            $cumulativemarkintensity += $intensity[$i];
            $markcount ++;
        }
    }
 
    if ($markcount > 0) {
       $averagemarkintensity = $cumulativemarkintensity / $markcount;
    } else {
       die "No marks detected in sample";
    }

    print "Average mark intensity  = $averagemarkintensity\n";

    foreach $i (0 .. @intensity - 1) {
        # normalise intensity to a scale 0 .. 3
        $relativeintensity = $intensity[$i] * 3.0 / $averagemarkintensity;

        if ($relativeintensity > 2.0
            and not $mark
            and $markspaceduration > $msdurthreshold) {
            $mark = 1;
            
            if ($waitingtostart ) {
                $waitingtostart = 0;
            } else {
                if ($markspaceduration < $maxdit) {
                    BuildHistogram('Element Gap', $markspaceduration);
                } elsif ($markspaceduration < $maxchargap) {
                    BuildHistogram('Character Gap', $markspaceduration);
                } else {
                    BuildHistogram('Word Gap', $markspaceduration); 
                }
            }

            $markspaceduration = 0;
        } elsif ($relativeintensity < 1.0
            and $mark
            and $markspaceduration > $msdurthreshold) {
	    $mark = 0;

            if ($markspaceduration < $maxdit) {
                BuildHistogram('Dot', $markspaceduration);
            } else {
                BuildHistogram('Dash', $markspaceduration);
            }

            $markspaceduration = 0;
        } else {
            if ($markspaceduration < 1000) { # sensible limit of 1 second
                $markspaceduration++;
            }
        }

        # print "$mark "; #diagnostics
    }
}

sub SummarizeSample {

    if (defined $meandot and defined $meanegap) {
       $meanpulse = ($meandot + $meanegap) / 2;
       $dotwpm = 1200 / $meanpulse;
       $dotweight = $meandot / $meanpulse;

       print "Dots sent at $dotwpm wpm, with length $dotweight pulses\n";
       if (defined $meandash) {
          $dashweight = $meandash / $meanpulse;
          print "Dash length is $dashweight pulses\n";
       }

       if (defined $meancgap) {
          $cgapweight = $meancgap / $meanpulse;
          print "Character gap length is $cgapweight pulses\n";
       }       

       if (defined $meanwgap) {
          $wgapweight = $meanwgap / $meanpulse;
          print "Word gap length is $wgapweight pulses\n";
       }

    }
}

sub ReplaySample {
    while(1) {
        print "Enter P to play sample, else quit:\n";
        $action = <STDIN>;
        chomp $action;
        last unless uc($action) eq 'P';

        # Play it back

        open (AU2, "| aplay -t raw -f U8 -r $samplingrate") or
           die "Could not pipe data to aplay\n";
         
        binmode(AU2);
        print AU2 $rawaudio;
        close(AU2);
   }

   #print "@datavalues"; #diagnostics
}

sub BuildHistogram {
   my $type = shift;
   my $duration = shift;

   my $x = int($duration / $histogramwidth);

   if (defined $histogram{$type}[$x]) {
      $histogram{$type}[$x]++;
    } else {
	$histogram{$type}[$x] = 1;
    }
}

sub ReportHistogram {
   my $type = shift;

   print "$type histogram:\n";

   foreach my $x (0 .. scalar(@{@histogram{$type}})) {
      $samples = $histogram{$type}[$x];
      
      if (defined $samples) {
         print "\t" . ($x * $histogramwidth) . "\t" . $samples . "\n";
       }
   }

   print "\n";

   ($mean, $stddev) = HistogramStats($type);

   if (defined $mean) { 
      print "Mean: $mean, SD: $stddev \n\n";
   } 

   return $mean;
}

sub HistogramStats {
   my $type = shift;

   my $sumsamples = 0;
   my $sumvalues = 0.0;
   my $sumsquares = 0.0;

   my $mean;

   foreach my $x (0 .. scalar(@{@histogram{$type}})) {
      $samples = $histogram{$type}[$x];

      if (defined $samples) {
         $sumsamples += $samples;
         $centralvalue = $histogramwidth * ($x + 0.5);
         $sumvalues += $centralvalue * $samples;
         $sumsquares += $centralvalue * $centralvalue * $samples;
      }
   }

   my $stddev = 0;

   if ($sumsamples > 0) {
      $mean = $sumvalues / $sumsamples;

      if ($sumsamples > 1) {
         $stddev = sqrt((($sumsquares / $sumsamples) - $mean * $mean) * $sumsamples / ($sumsamples - 1));
      }
   }

   return $mean, $stddev;
}
