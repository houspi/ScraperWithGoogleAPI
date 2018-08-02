#!/usr/bin/perl -w
#
# IndianapolisChildCare.pl
# SCRAPPING SCRIPT FOR THE WEBSITE                         
# https://secure.in.gov/apps/fssa/providersearch/home
# Indianapolis Child Care Provider Search
#
# By houspi@gmail.com
#  1.0.0/10.05.2018 
#  1.0.1/22.05.2018 
#  1.0.2/23.05.2018 
#-----------------------
# Files:
#  In 
#     IndianapolisChildCareFields.txt
#     IndianapolisZips.txt
#  Auxiliry    
#     IndianapolisZipsDone.txt		- Processed Zips
#  Out
#     IndianapolisChildCare.csv
#     IndianapolisInspections.csv
#
# On restart from scratch files IndianapolisChildCare.csv, IndianapolisInspections.csv, IndianapolisZipsDone.txt should be deleted
# On restart after failure script will continue using this files
#
#CHANGES
# 1.0.1 - changed the list of fields
# 1.0.2 - fixed some bugs
#
#-----------------------

use strict;
use WWW::Mechanize;
use HTML::TreeBuilder;
use utf8;
use Encode;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use HTML::FormatText;
use Data::Dumper;
use URI::URL;
use FileHandle;
use Time::HiRes qw(gettimeofday);
use JSON;

my $DEBUG     = 1;
my $MaxRetry  = 3;
my $MaxSleep  = 10;
my $StateName = "Indianapolis";
my $USE_PROXY = 0;
my $PROXY_HOST = "http://167.99.235.248";
my $PROXY_PORT ="3128";

my $ChildCare          = "IndianapolisChildCare.csv";
my $InspectionsReports = "IndianapolisInspections.csv";
my $CountiesList       = "IndianapolisZips.txt";
my $CountiesDone       = "IndianapolisZipsDone.txt";
my $FieldListFile      = "IndianapolisChildCareFields.txt";
my $GoogleKeyAPI = 'putYourGoogleKeyThere';

my $BaseUrl     = 'https://secure.in.gov';
my $StartPath   = '/apps/fssa/providersearch/home';
my $SearchPath  = '/apps/fssa/providersearch/api/providers/childCareSearch';
my $DetailsPath = '/apps/fssa/providersearch/api/providers/search/id';
my $ResultsPath = '';
my $NextPagePath = '';
my $InspectionsPath = "/";
my $page_size = 10000;

my %AgesCategories = (
    "47" => "Infants", 
    "48" => "Toddler", 
    "49" => "Preschooler", 
    "50" => "Gradeschooler", 
    );
my %TypesCategories = (
    "61" => 'Licensed Center', 
    "60" => 'Licensed Home', 
    "64" => 'Unlicensed Center', 
    "63" => 'Unlicensed Home', 
    "62" => 'Unlicensed Ministry', 
    );

print_debug(1, "Script for scraping of $StateName Child Care $BaseUrl$StartPath is starting at ".currentTime(), "\n");

#Field list defintion;
my @FieldList;
open FIELDS,"<$FieldListFile" or die "Can't define fields, No file $FieldListFile";
while (<FIELDS>) {
    chomp;
    next if /^#/ || /^\s*$/;
    my @FD = split "\t";
    push @FieldList,$FD[0] if $FD[1];
}
close FIELDS;
my %ProviderTmpl;
foreach my $field (@FieldList) { $ProviderTmpl{$field} = ''; }


# Read Zips List
my %Counties;
my $CountiesCount=0;
if (open(ZIPS, $CountiesList)) {
    while (<ZIPS>) {
        chomp;
        my @Values = split "\t",$_;
        if($Values[0] =~ /\d/) {
            $Counties{$Values[0]} = $Values[1];
            $CountiesCount++;
        }
    }
    close ZIPS;
}

# Read Processed Zips
my %CountiesDone;
if (open(ZIPS, $CountiesDone)) {
    while(<ZIPS>) {
        chomp;
        $CountiesDone{$_} = 1;
    }
}
close ZIPS;

# Read Processed providers
my %ProvidersDone = ();
if (open(CC, $ChildCare)) {
    while(<CC>) {
        chomp;
        my ($ProviderId, $tail) = split "\t", $_, 2;
        $ProvidersDone{$ProviderId} = 1;
    }
}

# Print headers to ouptul file
unless ( -e $ChildCare ) {
    open OUTDAT,">>", $ChildCare;
    print OUTDAT join("\t", @FieldList);
    print OUTDAT "\n";
    close OUTDAT;
}
unless ( -e $InspectionsReports ) {
    open OUTDAT,">>", $InspectionsReports;
    print OUTDAT "ProviderID\tDate\tType\tCorrection needed\tRegulation\tAction needed\tDate resolved\tProvider response\n";
    close OUTDAT;
}

my $mech;
{
	local $^W = 0;
	$mech = WWW::Mechanize->new( autocheck => 1, ssl_opts => {verify_hostname => 0,SSL_verify_mode => 0} );
}
$mech->timeout(30);
$mech->default_header('User-Agent'=>'Mozilla/5.0 (Windows NT 5.1; rv:11.0) Gecko/20100101 Firefox/11.0');
$mech->default_header('Accept'=>'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
$mech->default_header('Accept-Language'=>'en');
$mech->default_header('Accept-Encoding'=>'gzip, deflate');
$mech->default_header('Connection'=>'keep-alive');
$mech->default_header('Pragma'=>'no-cache');
$mech->default_header('Cache-Control'=>'no-cache');
$mech->proxy(['http', 'https'], "$PROXY_HOST:$PROXY_PORT") if $USE_PROXY;

my $i=0;
my $total = 0;
foreach my $Zip (sort keys %Counties) {
    $i++;
    print_debug(1, "$Zip => $Counties{$Zip} ($i/$CountiesCount)", "...");
    if (exists($CountiesDone{$Zip})) { print_debug(1, "already processed\n"); next; }
        my @Providers = ();
        my @Inspections = ();
        &ReTry($BaseUrl . $StartPath, $mech, $MaxRetry, $MaxSleep);
        ProcessCounty($mech, $Zip, \@Providers, \@Inspections);
        print_debug(1, "done\n");
        PrintOut($Zip, \@Providers, \@Inspections);
}

print_debug(1, "Script for scraping of $BaseUrl$StartPath is finished at ".currentTime(), "\n");

exit 0;

=head1 ProcessCounty
Process County
str
=cut
sub ProcessCounty {
    my $mech = shift;
    my $Zip = shift;
    my $Providers = shift;
    my $Inspections = shift;

    my $GoogleMech = $mech->clone();
    $GoogleMech->proxy(['http', 'https'], "");
    my $GooleApiUrl = 'https://maps.googleapis.com/maps/api/geocode/json?address=IN+' . $Counties{$Zip} . '+' . $Zip . '&key=' . $GoogleKeyAPI;
    my ($RetCode, $Errm) = &ReTry($GooleApiUrl, $GoogleMech, $MaxRetry, $MaxSleep);
    my $GoogleJson = $GoogleMech->content(decoded_by_headers => 1);
    my $json = decode_json($GoogleJson);
    my $LAT = $json->{'results'}->[0]->{'geometry'}->{'location'}->{'lat'};
    my $LNG = $json->{'results'}->[0]->{'geometry'}->{'location'}->{'lng'};
    my $nlat = $json->{'results'}->[0]->{'geometry'}->{'viewport'}->{'northeast'}->{'lat'};
    my $nlng = $json->{'results'}->[0]->{'geometry'}->{'viewport'}->{'northeast'}->{'lng'};
    my $slat = $json->{'results'}->[0]->{'geometry'}->{'viewport'}->{'southwest'}->{'lat'};
    my $slng = $json->{'results'}->[0]->{'geometry'}->{'viewport'}->{'southwest'}->{'lng'};

    my $SearchMech = $mech->clone();
    $SearchMech->proxy(['http', 'https'], "$PROXY_HOST:$PROXY_PORT") if $USE_PROXY;
    $SearchMech->default_header('Accept'=>'application/json, text/plain, */*');
    my $content = '{"openHours":null,"categoryIds":["676","677","678","679","680"],' . 
            '"coordinates":{"LAT":' . $LAT . ',"LNG":' . $LNG . '},' . 
            '"searchArea":{"northEast":{"lat":' . $nlat . ',"lng":' . $nlng . '},' . 
            '"southWest":{"lat":' . $slat . ',"lng":' . $slng . '}},' . 
            '"pageNumber":1,"pageSize":' . $page_size . '}';
    my $response = $SearchMech->post(
        $BaseUrl . $SearchPath, 
        'Content-Type' => 'application/json', 
        Content => $content
    );
    if ($response->is_success) {
        my $json = decode_json($SearchMech->content(decoded_by_headers => 1));
        my $count = scalar(@{$json->{'providers'}});
        print_debug(1, "found $count providers ");
        $total += $count;
        foreach my $item ( @{$json->{'providers'}} ) {
            if( !exists($ProvidersDone{$item->{'id'}}) ) {
                ProcessProvider($SearchMech, $item, $Providers, $Inspections);
                $ProvidersDone{$item->{'id'}} = 1;
            }
        }
        
    } else {
        print "ERROR\n";
    }

}


=head1 ProcessProvider
Get detail information about provider
str
=cut
sub ProcessProvider {
    my $mech = shift;
    my $item = shift;
    my $Providers = shift;
    my $Inspections = shift;

    print_debug(2, $item->{'id'}, $item->{'name'}, "\n");

    my %Provider = %ProviderTmpl;
    sleep int(rand($MaxSleep));
    my $DetailsMech = $mech->clone();
    $DetailsMech->proxy(['http', 'https'], "$PROXY_HOST:$PROXY_PORT") if $USE_PROXY;
    $DetailsMech->default_header('Accept'=>'application/json, text/plain, */*');
    my $response = $DetailsMech->post(
        $BaseUrl . $DetailsPath, 
        'Content-Type' => 'application/json', 
        Content => '{"providerId":"' . $item->{'id'} . '","locationId":"' . $item->{'location'}->{'id'} . '","coordinates":{"LAT":39.76065,"LNG":-86.158045}}'
    );
    if ($response->is_success) {
        my $json = decode_json($DetailsMech->content(decoded_by_headers => 1));
        $Provider{'ProviderID'} = $item->{'id'};
        $Provider{'Name'} = $json->{'provider'}->{'name'};
        $Provider{'Address'} = $json->{'provider'}->{'location'}->{'line1'};
        $Provider{'City'} = $json->{'provider'}->{'location'}->{'city'};
        $Provider{'County'} = $json->{'provider'}->{'location'}->{'counties'}->[0]->{'name'};
        $Provider{'State'} = $json->{'provider'}->{'location'}->{'state'};
        $Provider{'ZIP'} = $json->{'provider'}->{'location'}->{'zipCode'};
        $Provider{'Phone'} = $json->{'provider'}->{'location'}->{'phoneNumber'};

        if ( exists($json->{'provider'}->{'location'}->{'licensedAges'}) ) {
            my $capacity = 0;
            my $ages = '';;
            foreach  (@{$json->{'provider'}->{'location'}->{'licensedAges'}}) {
                $ages .= "; " if ( $ages );
                $ages .= $_->{'startAge'};
                $ages .= "-" . $_->{'endAge'} if ( exists($_->{'endAge'}) );
                $capacity += $_->{'quantity'};
            }
            $Provider{'Child Care Ages'} = $ages;
            $Provider{'Capacity'} = $capacity;
        }
        $Provider{'Applicants'} = $json->{'provider'}->{'location'}->{'applicants'}->[0]->{'name'};
        $Provider{'Status'} = $json->{'provider'}->{'location'}->{'status'};;
        $Provider{'License Start Date'} = $json->{'provider'}->{'location'}->{'license'}->{'effectiveDate'};
        $Provider{'License End Date'} = $json->{'provider'}->{'location'}->{'license'}->{'terminationDate'};
        $Provider{'License Status'} = $json->{'provider'}->{'location'}->{'license'}->{'typeDescription'};
        $Provider{'Type'} = $json->{'provider'}->{'location'}->{'providerType'};
        if ( exists($json->{'provider'}->{'location'}->{'programs'}) ) {
            foreach  (@{$json->{'provider'}->{'location'}->{'programs'}}) {
                $Provider{'Programs'} .= $_->{'programDescription'} . "; ";
            }
            $Provider{'Programs'} =~ s/; $//;
        }
        if ( exists($json->{'provider'}->{'location'}->{'accreditations'}) ) {
            foreach  (@{$json->{'provider'}->{'location'}->{'accreditations'}}) {
                $Provider{'Accreditations'} .= $_->{'name'} . "; ";
            }
            $Provider{'Accreditations'} =~ s/; $//;
        }
        $Provider{'PTQ Level'} = $json->{'provider'}->{'location'}->{'ptqLevel'};
        if ( exists($json->{'provider'}->{'location'}->{'schedule'}) ) {
            foreach (@{$json->{'provider'}->{'location'}->{'schedule'}}) {
                $Provider{$_->{'dayOfWeek'}} = $_->{'openTime'} . "-" . $_->{'closeTime'};
            }
        }
        push(@$Providers, \%Provider);
        if ( exists($json->{'provider'}->{'location'}->{'inspections'}) ) {
            foreach (@{$json->{'provider'}->{'location'}->{'inspections'}}) {
                my %Inspection;
                $Inspection{'ProviderID'} = $item->{'id'};
                $Inspection{'Date'} = $_->{'surveyDate'};
                $Inspection{'Type'} = $_->{'departmentDescription'};
                $Inspection{'Correction needed'} = $_->{'noncomplianceStatement'};
                $Inspection{'Regulation'} = $_->{'centerRule'}->{'code'};
                $Inspection{'Action needed'} = $_->{'centerRule'}->{'description'};
                $Inspection{'Date resolved'} = $_->{'correctionDate'};
                $Inspection{'Provider response'} = $_->{'providerResponse'};
                foreach (keys %Inspection) {
                    $Inspection{$_} = '' unless (defined($Inspection{$_}));
                    $Inspection{$_} =~ s/\n//g;
                }
                push(@$Inspections, \%Inspection);
            }
        }
        if ( exists($json->{'provider'}->{'location'}->{'complaints'}) ) {
            foreach (@{$json->{'provider'}->{'location'}->{'complaints'}}) {
                my %Inspection;
                $Inspection{'ProviderID'} = $item->{'id'};
                $Inspection{'Date'} = $_->{'complaintDate'};
                $Inspection{'Type'} = 'Complaints';
                $Inspection{'Correction needed'} = $_->{'issue'};
                $Inspection{'Regulation'} = $_->{'centerRule'}->{'code'};
                $Inspection{'Action needed'} = $_->{'centerRule'}->{'description'};
                $Inspection{'Date resolved'} = $_->{'closedDate'};
                $Inspection{'Provider response'} = $_->{'providerResponse'};
                foreach (keys %Inspection) {
                    $Inspection{$_} = '' unless (defined($Inspection{$_}));
                    $Inspection{$_} =~ s/\n//g;
                }
                push(@$Inspections, \%Inspection);
            }
        }
        
    }
}


sub PrintOut {
    my $county = shift;
    my $Providers   = shift;
    my $Inspections = shift;

    print_debug(2, "Store providers to file\n");
    open OUTDAT, ">>", $ChildCare;
    binmode(OUTDAT, ":utf8");
    OUTDAT->autoflush(1);
    foreach my $provider (@$Providers) {
        foreach my $field (@FieldList) {
                printf OUTDAT "%s\t", $provider->{$field} ? $provider->{$field} : "";
        }
        print OUTDAT "\n";
    }
    close OUTDAT;

    open OUTDAT, ">>", $InspectionsReports;
    binmode(OUTDAT, ":utf8");
    OUTDAT->autoflush(1);
	foreach my $inspections (@$Inspections) {
	    printf OUTDAT "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", 
                        $inspections->{'ProviderID'}, 
                        $inspections->{'Date'},
                        $inspections->{'Type'},
                        $inspections->{'Correction needed'},
                        $inspections->{'Regulation'},
                        $inspections->{'Action needed'},
                        $inspections->{'Date resolved'},
                        $inspections->{'Provider response'};
	}
	close OUTDAT;

    open OUTDAT, ">>", $CountiesDone;
    binmode(OUTDAT, ":utf8");
    OUTDAT->autoflush(1);
    printf OUTDAT "%s\n", $county;
    close OUTDAT;
}

=head1 ReTry
Trying to get URL
Url
mech
RetryLimit
MaxSleep
=cut
sub ReTry {
    my $Url        = shift;
    my $mech       = shift;
    my $RetryLimit = shift;
    my $MaxSleep   = shift;
    $RetryLimit = 5 if(!$RetryLimit);
    $MaxSleep   = 1 if(!$MaxSleep);
    # Set a new timeout, and save the old one
    my $OldTimeOut = $mech->timeout(30);
    my $ErrMAdd;
    my $TryCount = 0;
    
    while ($TryCount <= $RetryLimit) {
        $TryCount++;
        sleep int(rand($MaxSleep));
        # Catch the error
        # Return if no error
        print_debug(3, "ReTry", $Url, "\n");
        eval { $mech->get($Url); };
        if ($@) {
            print_debug(3, "Attempt $TryCount/$RetryLimit...\t$Url", $@, "\n");
            $ErrMAdd = $@;
        }
        else {
            print_debug(3, "ReTry Success\n");
            $mech->timeout($OldTimeOut); 
            return 1;
        }
    }
    # Restore old timeout
    $mech->timeout($OldTimeOut);    
    # Return failure if the program has reached here
    return (0,"Can't connect to $Url after $RetryLimit attempts ($ErrMAdd)....");
}

=head1 currentTime
return current time in format YYYY-MM-DD HH-MM-SS
=cut
sub currentTime {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    $year += 1900;
    $mon++;
    return sprintf("%4d-%02d-%02d %02d:%02d:%02d", $year, $mon, $mday, $hour, $min, $sec);
    
    return "$year-$mon-$mday ". "$hour:$min:$sec";
}

=head1 trim
trim leading and trailing spases 
str
=cut
sub trim {
    my $str = $_[0];
    $str = (defined($str)) ? $str : "";
    $str =~ s/^\s+|\s+$//g;
    return($str);
}

=head1 print_debug
print debug info
=cut
sub print_debug {
    my $level = shift;
    if ($level <= $DEBUG) {
        print STDERR join(" ", @_);
    }
}
