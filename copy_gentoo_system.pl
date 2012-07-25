#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';
use Data::Dumper;
use Cwd 'abs_path';
use Digest::MD5::File qw( file_md5_hex );
use File::Temp qw( tempdir );
use File::Find;
use File::Glob ':glob';

my %objects;

use constant PREFIX => $ARGV[0];
use constant DRYRUN => 0;
use constant SOURCE => '/dev/sda';
#use constant SOURCE_BOOT => '/dev/sda1';
#use constant SOURCE_ROOT => '/dev/sda2';

if (@ARGV != 1)
{
	print "Usage: $0 device\n";
	exit 0;
}

if (! -b PREFIX)
{
	print PREFIX." not a block device!\n";
	exit 1 unless(DRYRUN);
}

open MOUNT, "mount|";
while (<MOUNT>)
{
	if(substr($_, 0, length(PREFIX)) eq PREFIX)
	{
		say "Error! destination partition mounted!:";
		say "  $_";
		exit 2;
	}
}
close MOUNT;

# read the partition table
my $total_sectors;
my $pre_partition_space;
my $sector_size;
open PARTITION, "fdisk -l '".PREFIX."'|";
while (<PARTITION>)
{
	$total_sectors = $1 if $_ =~ /, total (\d+) sectors/;
	$sector_size = $1 if $_ =~ /Units = sectors of .* = (\d+) bytes/;
	$pre_partition_space = $1 if(!$pre_partition_space && /^\/[^ ]+\s+(?:\*\s+)?(\d+)/);
}
close PARTITION;
die "Could not get total sectors on source disk" unless($total_sectors || DRYRUN);
die "Could not get sector size on source disk" unless($sector_size || DRYRUN);
die "Could not get pre-partition space" unless($pre_partition_space || DRYRUN);

# copy the MBR and space before first partition
if (!DRYRUN)
{
	say "running: ".join(" ", ("dd", "if=".SOURCE, "of=".PREFIX, "bs=$sector_size", "count=$pre_partition_space"));
	system "dd", "if=".SOURCE, "of=".PREFIX, "bs=$sector_size", "count=$pre_partition_space";
}


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
close PARTITION;
$partition_table =~ s/($last_partition : start=\s*)(\d+), size=\s*\d+,/"$1$2, size=".($total_sectors-$2).","/me;
# I don't think this is necessary, but I'm really scared of having the source in the partiion table
$partition_table =~ s/${\(SOURCE)}/${\(PREFIX)}/gm;

print "---------- BEGIN PARTITION TABLE ----------\n$partition_table\n---------- END PARTITION TABLE ----------\n";
if (!DRYRUN)
{
	open SFDISK, "|sfdisk ".PREFIX;
	print SFDISK $partition_table;
	close SFDISK;
}

# give udev a chance to create partition devices
system "fdisk", "-l", PREFIX;
sleep 2;

# format the partitions
open FSTAB, '</etc/fstab';
my $new_boot_partition;
my $new_root_partition;
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
	if (!DRYRUN)
	{
		system "/sbin/mkfs.$type", $newpartition;
	}
	$new_boot_partition = $newpartition if($mountpoint eq '/boot');
	$new_root_partition = $newpartition if($mountpoint eq '/');
}

die "Unable to determine boot partition" unless($new_boot_partition);

my $tmp_mount = tempdir();
say "Using temporary mount point: $tmp_mount";

# copy boot partition
if (!DRYRUN)
{
	system "mount", "-o", "ro", "/boot";
	system "mount", $new_boot_partition, $tmp_mount;
	system "rsync", "-aH", "/boot/.", $tmp_mount."/.";
	system "umount", "/boot";
	system "umount", $tmp_mount;
}

#exit;

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

my %copy_files;
my %diff_files;
my %missing_files;
for my $obj (keys %objects)
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
		if (!-e $obj)
		{
			say "missing $obj";
			$missing_files{$obj} = 1;
		}
		else
		{
			my $file_md5 = file_md5_hex($obj);
			if ($objects{$obj}->{file} eq $file_md5)
			{
				say "copy $obj";
				$copy_files{$obj} = 1;
			}
			else
			{
				say "diff $obj";
				$diff_files{$obj} = 1;
			}
		}
	}
}

for my $whitelist (<whitelists.d/*>)
{
	say "using whitelist file $whitelist";
	open WHITELIST, "<$whitelist";
	while(<WHITELIST>)
	{
		s/#.*//;
		s/^\s*//;
		s/\s*$//;
		next unless($_);
		say "  using whitelist $_";
		if (/^(.*?)(?:\/\.\.\.(\/.*)?)?$/)
		{
			my $dir_glob = $1;
			my $glob_end = $2 ? $2 : "";
			for my $dir (glob($dir_glob))
			{
				find(sub {
						my @files;
						if ($glob_end)
						{
							my $glob_pattern = $File::Find::name;
							$glob_pattern =~ s/([\[\]\{\}\?\~'"])/\\$1/g;
							$glob_pattern .= $glob_end;
							@files = bsd_glob($glob_pattern, "GLOB_QUOTE");
						}
						else
						{
							@files = ($File::Find::name);
						}
						for my $file (@files)
						{
							$copy_files{$file} = 1;
							delete $diff_files{$file};
						}
					}, $dir);
			}
		}
		elsif(!-e $_)
		{
			$missing_files{$_} = 1;
		}
		else
		{
			$copy_files{$_} = 1;
			delete $diff_files{$_};
		}
	}
}

sub slash_sort(@) {
	return (sort { my @a = $a =~ m#/#g; my @b = $b =~ m#/#g; $#a <=> $#b or $a cmp $b } @_);
}

open COPY, '>copy.txt';
say COPY $_ for(slash_sort keys %copy_files);
close COPY;

open DIFF, '>diff.txt';
say DIFF $_ for(slash_sort keys %diff_files);
close DIFF;

open MISSING, '>missing.txt';
say MISSING $_ for(slash_sort keys %missing_files);
close MISSING;

if (!DRYRUN)
{
	system "mount", $new_root_partition, $tmp_mount;
	say "Going to run: ", join(' ', ("rsync", "-aH", "--log-file=rsync.log", "--files-from","copy.txt","/", $tmp_mount."/."));
	system "rsync", "-aH", "--log-file=rsync.log", "--files-from","copy.txt","/", $tmp_mount."/.";
	system "umount", $tmp_mount;
}
