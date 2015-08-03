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
use File::Basename;
$| = 1;

my %objects;
my @error_files;

use constant DESTINATION => $ARGV[0];
use constant DRYRUN => 0;
use constant SOURCE => '/dev/sda';
use constant JUSTFILES => 0;
#use constant SOURCE_BOOT => '/dev/sda1';
#use constant SOURCE_ROOT => '/dev/sda2';

sub run(@)
{
	if (DRYRUN)
	{
		say "pretend: ".join(" ", @_);
	}
	else
	{
		say "running: ".join(" ", @_);
		system @_;
	}
}

if (@ARGV != 1)
{
	print "Usage: $0 device\n";
	exit 0;
}

if (! -b DESTINATION)
{
	print DESTINATION." not a block device!\n";
	exit 1 unless(DRYRUN);
}

my $new_boot_partition;
my $new_root_partition;
my $root_partition_mapper;
my $tmp_mount;

sub clearline()
{
	return "\r\033[K";
}

if(!JUSTFILES)
{
	open MOUNT, "mount|";
	while (<MOUNT>)
	{
		if(substr($_, 0, length(DESTINATION)) eq DESTINATION)
		{
			say "Error! destination partition mounted!:";
			say "  $_";
			exit 2;
		}
	}
	close MOUNT;

	say "********************************************************************************";
	say "**                         OVERWRITE THIS DRIVE?                              **";
	say "********************************************************************************";
	system "/sbin/fdisk", "-l", DESTINATION;
	say "********************************************************************************";
	say "**                             ARE YOU SURE?                                  **";
	say "********************************************************************************";
	say "type yes to continue";
	my $confirmation = <STDIN>;
	chomp $confirmation;
	if($confirmation ne 'yes')
	{
		say "Confirmation not given. Quitting.";
		exit;
	}

	# read the partition table
	my $total_sectors;
	my $pre_partition_space;
	my $sector_size;
	open PARTITION, "/sbin/fdisk -l '".SOURCE."'|";
	while (<PARTITION>)
	{
		$total_sectors = $1 if $_ =~ /, (\d+) sectors$/;
		$sector_size = $1 if $_ =~ /Units[ =:]* sectors of .* = (\d+) bytes/;
		$pre_partition_space = $1 if(!$pre_partition_space && /^\/[^ ]+\s+(?:\*\s+)?(\d+)/);
	}
	close PARTITION;
	die "Could not get total sectors on source disk" unless($total_sectors || DRYRUN);
	die "Could not get sector size on source disk" unless($sector_size || DRYRUN);
	die "Could not get pre-partition space" unless($pre_partition_space || DRYRUN);

	# copy the MBR and space before first partition
	run("dd", "if=".SOURCE, "of=".DESTINATION, "bs=$sector_size", "count=$pre_partition_space");

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
	$partition_table =~ s/${\(SOURCE)}/${\(DESTINATION)}/gm;

	print "---------- BEGIN PARTITION TABLE ----------\n$partition_table\n---------- END PARTITION TABLE ----------\n";
	if (!DRYRUN)
	{
		open SFDISK, "|sfdisk ".DESTINATION;
		print SFDISK $partition_table;
		close SFDISK;
	}

	# give udev a chance to create partition devices
	system "fdisk", "-l", DESTINATION;
	sleep 2;

	# format the partitions
	open FSTAB, '</etc/fstab';
	while(<FSTAB>)
	{
		chomp;
		s/#.*//;
		next unless my ($partition, $mountpoint, $type) = (/^\s*(\S+)\s+(\S+)\s+(\S+).*/);
		if ($partition =~ m#^/dev/mapper#)
		{
			say "looking at mapped device $partition";
			open DM_STATUS, "cryptsetup status $partition |";
			while(<DM_STATUS>)
			{
				my $mapped_device;
				if (($mapped_device) = (/^\s*device:\s+(\S+)/))
				{
					last unless substr($mapped_device, 0, length(SOURCE)) eq SOURCE;
					$root_partition_mapper = $partition if($mountpoint eq '/');
					$partition = $mapped_device;
					last;
				}
			}
			close DM_STATUS;
		}
		next unless substr($partition, 0, length(SOURCE)) eq SOURCE;

		my $newpartition = $partition;
		substr($newpartition, 0, length(SOURCE)) = DESTINATION;
		print "Formatting $newpartition for $partition of type $type at $mountpoint\n";
		die "Unable to find mkfs for type $type" unless -x "/sbin/mkfs.$type";
		run("/sbin/mkfs.$type", $newpartition);

		$new_boot_partition = $newpartition if($mountpoint eq '/boot');
		$new_root_partition = $newpartition if($mountpoint eq '/');
		say "... $mountpoint";
	}

	die "Unable to determine boot partition" unless($new_boot_partition);
	die "Unable to determine root partition" unless($new_root_partition);

	$tmp_mount = tempdir();
	say "Using temporary mount point: $tmp_mount";

	# copy boot partition
	run("mount", "-o", "ro", "/boot");
	run("mount", $new_boot_partition, $tmp_mount);
	run("rsync", "--verbose", "-aH", "/boot/.", $tmp_mount."/.");
	run("umount", "/boot");
	run("umount", $tmp_mount);
} # not JUSTFILES

say "scanning portage files...";
for my $contentsFile (</var/db/pkg/*/*/CONTENTS>)
{
	open H, "<$contentsFile" or die;
	while (<H>)
	{
		if (/^dir (.*)$/)
		{
			die $1 unless(abs_path($1));
			$objects{abs_path($1)}->{directory} = 1;
		}
		if (/^obj (.*) ([0-9a-f]{32}) \d+$/)
		{
			my $final_path = abs_path($1);
			if(!$final_path)
			{
				# blarg http://www.gossamer-threads.com/lists/perl/porters/293164
				#die "?? ($1) $_ $contentsFile";
				say "ERROR HERE: $1 $_ $contentsFile ($contentsFile)";
				push @error_files, $1;
				next;
			}
			$objects{$final_path}->{file} = $2;
		}
		if (/^sym (.*) -> (.*) \d+$/)
		{
			$objects{$1}->{symlink} = 1;
		}
	}
}

say "processing portage files...";
my %copy_files;
my %diff_files;
my %missing_files;
my $num_objects = scalar(keys %objects);
my $objects_processed = 0;
my $start_time = time();
my $eta = "??";
for my $obj (keys %objects)
{
	$objects_processed++;
	if($objects_processed && $objects_processed % 1000 == 0)
	{
		my $elapsed_time = time() - $start_time;
		my $expected_time = $elapsed_time / ($objects_processed / $num_objects);
		my $expected_remaining = $expected_time - $elapsed_time;
		$eta = sprintf "%0dm%02ds", int($expected_remaining/60), $expected_remaining % 60;
	}

	printf clearline()."%d / %d (%0.02f%%) ETA: %s", $objects_processed, $num_objects, 100*$objects_processed / $num_objects, $eta;
	if ($objects{$obj}->{symlink})
	{
		#my $dest = $objects{$obj}->{symlink};
		#$dest = DESTINATION . $dest if($dest =~ /^\//);
		#print "SYM $obj -> $dest\n";
		#symlink $dest, DESTINATION . "/$obj" if(!DRYRUN);
		#say $obj;
	}
	elsif ($objects{$obj}->{directory})
	{
		#mkdir DESTINATION . $obj;
		#say $obj;
		if (!-d $obj)
		{
			$missing_files{$obj} = 1;
		}
		else
		{
			$copy_files{$obj} = 1;
		}
	}
	elsif ($objects{$obj}->{file})
	{
		#print "OBJ $obj\n";
		if (!-e $obj)
		{
			say clearline()."missing $obj";
			$missing_files{$obj} = 1;
		}
		else
		{
			my $file_md5 = file_md5_hex($obj);
			if ($objects{$obj}->{file} eq $file_md5)
			{
				#say "copy $obj";
				$copy_files{$obj} = 1;
			}
			else
			{
				say clearline()."diff $obj";
				$diff_files{$obj} = 1;
			}
		}
	}
}
say "";

my $exe_path = dirname(__FILE__);
my $whitelists_glob = "$exe_path/whitelists.d/*";
for my $whitelist (glob($whitelists_glob))
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
		if (/^(.*?)(?:(\/\.\.\.)(\/.*)?)?$/)
		{
			my $dir_glob = $1;
			my $dots = $2 ? $2 : "";
			my $glob_end = $3 ? $3 : "";
			#say "    dir_glob: [$dir_glob] dots: [$dots] glob_end: [$glob_end]";
			for my $dir (glob($dir_glob))
			{
				#say "      dir: [$dir]";
				if (!$dots)
				{
					if(!-e $dir)
					{
						$missing_files{$dir} = 1;
						say "    WARNING: whitelisted file ($dir) not found";
					}
					else
					{
						if (-l $dir)
						{
							$objects{$dir}->{symlink} = 1;
						}
						else
						{
							#my $file = abs_path($dir);
							$copy_files{$dir} = 1;
							delete $diff_files{$dir};
						}
					}
				}
				else
				{
					if(-e $dir)
					{
						find(sub {
								my @files;
								if ($glob_end)
								{
									my $glob_pattern = $File::Find::name;
									$glob_pattern =~ s/([\[\]\{\}\?\~'"])/\\$1/g;
									$glob_pattern .= $glob_end;
									@files = bsd_glob($glob_pattern, GLOB_QUOTE|GLOB_BRACE);
									say "    glob_pattern [$glob_pattern] :";
									say join("\n", map { "      $_" } @files) if(@files);
								}
								else
								{
									if (-l $File::Find::name)
									{
										$objects{$File::Find::name}->{symlink} = 1;
									}
									else
									{
										@files = ($File::Find::name);
									}
								}
								for my $file (@files)
								{
									my $real_file = abs_path($file);
									$copy_files{$real_file} = 1;
									delete $diff_files{$real_file};
								}
							}, $dir);
					}
					else
					{
						$missing_files{$dir} = 1;
						say "    WARNING: whitelisted file ($dir) not found";
					}
				}
			}
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

open SYMLINKS, '>symlinks.txt';
say SYMLINKS $_ for(slash_sort grep {$objects{$_}->{symlink}} keys %objects);
close SYMLINKS;

open ERROR, '>errors.txt';
say ERROR $_ for(slash_sort @error_files);
close ERROR;

if (!(JUSTFILES || DRYRUN))
{
	run("mount", $new_root_partition, $tmp_mount);
	run("rsync", "--verbose", "-aH", "--log-file=rsync.log", "--files-from","copy.txt","/", $tmp_mount."/.");

	for my $sym (slash_sort grep {$objects{$_}->{symlink}} keys %objects)
	{
		my $old = readlink($sym);
		my $new = $tmp_mount."/$sym";
		if(DRYRUN)
		{
			say "pretend: $old -> $new";
		}
		else
		{
			say "link $old -> $new";
			my $ret = symlink $old, $new;
			if(!$ret)
			{
				say "ERROR CREATING SYMLINK $!";
			}
		}
	}

	# The following devices and symlinks will be necessary after reboot
	run("mkdir", "-m", "766", "$tmp_mount/dev");
	run("mknod", "-m", "622", "$tmp_mount/dev/console", "c", 5, 1);
	run("mknod", "-m", "666", "$tmp_mount/dev/null", "c", 1, 3);
	run("mknod", "-m", "666", "$tmp_mount/dev/zero", "c", 1, 5);
	run("mknod", "-m", "666", "$tmp_mount/dev/ptmx", "c", 5, 2);
	run("mknod", "-m", "666", "$tmp_mount/dev/tty", "c", 5, 0);
	run("mknod", "-m", "444", "$tmp_mount/dev/random", "c", 1, 8);
	run("mknod", "-m", "444", "$tmp_mount/dev/urandom", "c", 1, 9);
	run("chown", "-v", "root:root", "$tmp_mount/dev/console");
	run("chown", "-v", "root:root", "$tmp_mount/dev/ptmx");
	run("chown", "-v", "root:root", "$tmp_mount/dev/tty");
	run("ln", "-sv", "/proc/self/fd", "$tmp_mount/dev/fd");
#	run("ln", "-sv", "/proc/self/fd/0", "$tmp_mount/dev/fd/stdin");
#	run("ln", "-sv", "/proc/self/fd/1", "$tmp_mount/dev/fd/stdout");
#	run("ln", "-sv", "/proc/self/fd/2", "$tmp_mount/dev/fd/stderr");
	run("ln", "-sv", "/proc/kcore", "$tmp_mount/core");
	run("mkdir", "-v", "$tmp_mount/dev/pts");
	run("mkdir", "-v", "$tmp_mount/dev/shm");

	run("mkdir", "-m", "666", "$tmp_mount/proc");
	run("mount", "-t", "proc", "none", "$tmp_mount/proc");

	run("mkdir", "-m", "666", "$tmp_mount/sys");
	run("mount", "--rbind", "/sys", "$tmp_mount/sys");

	run("mount", "--rbind", "/dev", "$tmp_mount/dev");

	# eselect-awk is still masked, nobody owns this symlink...
	run("chroot", $tmp_mount, "ln", "-sv", "gawk", "/usr/bin/awk");
	run("chroot", $tmp_mount, "ln", "-sv", "../usr/bin/gawk", "/bin/awk");

	run("chroot", $tmp_mount, "eselect", "python", "set", "1");
	run("chroot", $tmp_mount, "gcc-config", "1");
	open BINUTILS_CONF, '-|', "binutils -l";
	while(<BINUTILS_CONF>)
	{
		if(/^ \[(\d+)\].*\*$/)
		{
			run("chroot", $tmp_mount, "binutils-config", $1);
		}
	}
	run("chroot", $tmp_mount, "build-docbook-catalog");
	run("chroot", $tmp_mount, "eselect", "vi", "set", "1");

	my $opengl = `eselect opengl show`;
	run("chroot", $tmp_mount, "eselect", "opengl", "set", $opengl);
	open MESA_CONF, "eselect mesa show|";
	while(<MESA_CONF>)
	{
		run("chroot", $tmp_mount, "eselect", "mesa", "set", split /\s+/, $_);
	}

	my @wordlists = map { s/^$tmp_mount//; $_ } glob($tmp_mount."/usr/share/dict/*");
	run("chroot", $tmp_mount, "create-cracklib-dict", @wordlists);

	open BASHCOMP_CONF, '-|', "eselect bashcomp list --global";
	while(<BASHCOMP_CONF>)
	{
		if(/^ \[(\d+)\].*\*$/)
		{
			run("chroot", $tmp_mount, "eselect", "bashcomp", "enable", "--global", $1);
		}
	}

	if($root_partition_mapper)
	{
		run("chroot", $tmp_mount, "sed", "-i", "s#$root_partition_mapper#$new_root_partition#g", "/etc/fstab");
	}

	# configure users
	{
		run("rsync", "--verbose", "-aH", "/etc/passwd", $tmp_mount."/etc");
		my @users;
		my $shadow;
		open SHADOW, "</etc/shadow";
		while(<SHADOW>)
		{
			if(s/^([^:]*):(\$\d\$[^:]*)/$1:*/)
			{
				push @users, $1;
			}
			$shadow .= $_;
		}
		close SHADOW;
		open NEW_SHADOW, ">$tmp_mount/etc/shadow";
		print NEW_SHADOW $shadow;
		close NEW_SHADOW;
		chmod 0600, "$tmp_mount/etc/shadow";

		say "----------------------------------";
		for my $user (@users)
		{
			say "Enter password for user '$user'";
			run("chroot", $tmp_mount, "passwd", $user);
		}
	}

#
#	run("umount", "$tmp_mount/dev/shm", "$tmp_mount/dev/pts", "$tmp_mount/dev");
#	run("umount", "-l", "$tmp_mount/sys");
#	run("umount", "$tmp_mount/proc");
#	run("umount", $tmp_mount);
}

say "umount $tmp_mount/dev/{shm,pts,} $tmp_mount/proc ; umount -l $tmp_mount/sys ; umount $tmp_mount ; rmdir $tmp_mount";

