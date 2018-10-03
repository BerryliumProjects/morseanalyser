    use Audio::DSP;

    if ($ARGV[0] > 4) {
        $targetwpm = $ARGV[0];
    } else {
        $targetwpm = 15;
    }

    if ($ARGV[1] > 1) {
        $seconds = $ARGV[1];
    } else {
        $seconds = 10;
    }


    $histogramwidth = 10;
    $targetdit = int(1200 / $targetwpm);
    $maxdit = $targetdit * 2;
    $maxchargap = $targetdit * 5.5;
    print "Using $targetwpm wpm, dit is $targetdit ms. Splitting at $maxdit and $maxchargap ms. Sample duration $seconds s\n";


#    ($buf, $chan, $fmt, $rate) = (4096, 1, AFMT_S8, 8192);
    ($buf, $chan, $fmt, $rate) = (4096, 1, AFMT_S16_LE, 8192);

    $dsp = new Audio::DSP(buffer   => $buf,
                          channels => $chan,
                          format   => $fmt,
                          rate     => $rate);

    # change 16 to 8 to use AFMT_S8;

    $length  = ($chan * 16 * $rate * $seconds) / 8;
    $flushlength  = ($chan * 16 * $rate * 1) / 8;

    $dsp->init(mode => O_RDONLY) || die $dsp->errstr();

    # Ignore initial transient
    for (my $i = 0; $i < $flushlength; $i += $buf) {
        $dsp->read() || die $dsp->errstr();
    }

    $dsp->clear();
    print "Ready\n";

    # Record 5 seconds of sound
    for (my $i = 0; $i < $length; $i += $buf) {
        $dsp->read() || die $dsp->errstr();
    }
    $rawaudio = $dsp->data();
    $dsp->close();


    @datavalues = unpack('c*', $rawaudio);

    # apply filter to remove low frequencies

    @filtered1 = ();
    $runningsum = 0;

    $runninglength = 8;
    $intensitylength = 8;
    $newintensityweight = 1 / $intensitylength;
    $accintensityweight = 1 - $newintensityweight;

    $markspaceduration = 0;
    $mark = 0;
    $markthreshold = 7; # initial value, suitable for peak intensity 10
    $spacethreshold = $markthreshold / 2.0;
    $msdurmax = 8000;
    $peaksmoothedintensity = 0;
    $msdurthreshold = 160; # 20 ms
    $waitingtostart = 1;

    %histogram; # hash of arrays


    foreach $i (0 .. $runninglength - 1) {
	$runningsum += $datavalues[$i];
    }

    foreach $i ($runninglength .. @datavalues - 1) {
        $data1 = $datavalues[$i] - int($runningsum / $runninglength);
        push (@filtered1, $datavalues[$i] - $runningsum);
        $runningsum += ($datavalues[$i] - $datavalues[$i - $runninglength]);
# print $data1, "\n";    
        $intensity = ($data1 > 0 ? $data1 : -$data1);

        $smoothedintensity = $smoothedintensity * $accintensityweight + 
            $intensity * $newintensityweight;

        if ($smoothedintensity > $markthreshold
            and not $mark
            and $markspaceduration > $msdurthreshold) {
            $mark = 1;
            
            if ($waitingtostart ) {
                $waitingtostart = 0;
            } else {
                $msdtime = int($markspaceduration * 1024 / $rate);
#                print "space duration = $msdtime\n";
 
                if ($msdtime < $maxdit) {
                    BuildHistogram('Element Gap', $msdtime);
                } elsif ($msdtime < $maxchargap) {
                    BuildHistogram('Character Gap', $msdtime);
                } else {
                    BuildHistogram('Word Gap', $msdtime); 
                }

            }

            $markspaceduration = 0;
        } elsif ($smoothedintensity < $spacethreshold
            and $mark
            and $markspaceduration > $msdurthreshold) {
	    $mark = 0;
           
            $msdtime = int($markspaceduration * 1024 / $rate);
#            print "mark duration = $msdtime\n";

            if ($msdtime < $maxdit) {
                BuildHistogram('Dot', $msdtime);
            } else {
                BuildHistogram('Dash', $msdtime);
            }

            $markspaceduration = 0;
            # recalibrate mark/space intensity edge levels
            $markthreshold = $peaksmoothedintensity * 2.0/3;
            $spacethreshold = $markthreshold / 2.0;
        } else {
            if ($markspaceduration < $msdurmax) {
                $markspaceduration++;
            }
           
            if ($mark and $smoothedintensity > $peaksmoothedintensity) {
                $peaksmoothedintensity = $smoothedintensity;
            }
        }
# print $intensity , ",", $smoothedintensity , "\n";
    }


    print "Final peak smoothed intensity  = $peaksmoothedintensity\n";

# show histogram stats

    $meandot = ReportHistogram('Dot');
    $meandash = ReportHistogram('Dash');
    $meanegap = ReportHistogram('Element Gap');
    $meancgap = ReportHistogram('Character Gap');
    $meanwgap = ReportHistogram('Word Gap');

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

#   foreach (@filtered1) { printf('%i8',$_);}

    open (RAWFILE, ">./dsptest.au");
    print RAWFILE $rawaudio;
    close (RAWFILE);

    while(1) {
        print "Enter P to play sample, else quit:\n";
        $action = <STDIN>;
        chomp $action;
        last unless uc($action) eq 'P';

        # Play it back
        $dsp = new Audio::DSP(buffer   => $buf,
                          channels => $chan,
                          format   => $fmt,
                          rate     => $rate);


        $dsp->init(mode => O_WRONLY) || die $dsp->errstr();
        $dsp->datacat($rawaudio);
        print "Buffer length: ",$dsp->datalen(), "\n";
        for (;;) {
            $dsp->write() || last;
        }

        $dsp->close();
    }

#print "@datavalues";

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
