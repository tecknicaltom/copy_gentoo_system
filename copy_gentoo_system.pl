#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';
use Data::Dumper;
use Cwd 'abs_path';

my %objects;

use constant PREFIX => $ARGV[0];
use constant DRYRUN => 1;
use constant SOURCE => '/dev/sda';
use constant SOURCE_BOOT => '/dev/sda1';
use constant SOURCE_ROOT => '/dev/sda2';

# abs_path('/dev/root')

if (@ARGV != 1)
{
	print "Usage: $0 device\n";
	exit 0;
}

if (! -b PREFIX)
{
	print PREFIX." not a block device!\n";
#	exit 1;
}

# read the partition table
my $partition_table;
my $last_partition;
open PARTITION, "sfdisk -d '".SOURCE."'|";
while (<PARTITION>)
{
	if (/^([^ ]+) : .* size=\s*(\d+),/ && $2)
	{
		$last_partition = $1;
	}
	$partition_table .= $_;
}
$partition_table =~ s/($last_partition : .* size=)\s*\d+,/$1+,/m;



# format the partitions
open FSTAB, '</etc/fstab';
while(<FSTAB>)
{
	chomp;
	s/#.*//;
	next unless my ($partition, $mountpoint, $type) = (/^\s*(\S+)\s+(\S+)\s+(\S+).*/);
	next unless substr($partition, 0, length(SOURCE)) eq SOURCE;
	my $newpartition = $partition;
	substr($newpartition, 0, length(SOURCE)) = PREFIX;
	print "Formatting $newpartition for $partition of type $type at $mountpoint\n";
	die "Unable to find mkfs for type $type" unless -x "/sbin/mkfs.$type";
	say "Calling: /sbin/mkfs.$type $newpartition";
	#system "/sbin/mkfs.$type", $newpartition;
}

exit;

for my $contentsFile (</var/db/pkg/*/*/CONTENTS>)
{
	open H, "<$contentsFile" or die;
	while (<H>)
	{
		if (/^dir (.*)$/)
		{
			$objects{abs_path($1)}->{directory} = 1;
		}
		if (/^obj (.*) ([0-9a-f]{32}) \d+$/)
		{
			$objects{abs_path($1)}->{file} = $2;
		}
		if (/^sym (.*\/)([^\/]*) -> (.*) \d+$/)
		{
			my ($base, $file, $dest) = ($1, $2, $3);
			$base = abs_path($base);
			my $src = $base.($base =~ /\/$/ ? '' : '/').$file;
			$objects{$src}->{symlink} = $dest;
		}
	}
}

for my $obj (sort { my @a = $a =~ m#/#g; my @b = $b =~ m#/#g; $#a <=> $#b } keys %objects)
{
	if ($objects{$obj}->{symlink})
	{
		my $dest = $objects{$obj}->{symlink};
		$dest = PREFIX . $dest if($dest =~ /^\//);
		#print "SYM $obj -> $dest\n";
		#symlink $dest, PREFIX . "/$obj" if(!DRYRUN);
		say $obj;
	}
	elsif ($objects{$obj}->{directory})
	{
		#mkdir PREFIX . $obj;
		say $obj;
	}
	elsif ($objects{$obj}->{file})
	{
		#print "OBJ $obj\n";
	}
}
