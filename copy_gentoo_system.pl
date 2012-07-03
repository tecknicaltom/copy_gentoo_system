#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';
use Data::Dumper;
use Cwd 'abs_path';

my %objects;

use constant PREFIX => '/root/copy_gentoo_system/test';
use constant DRYRUN => 1;

# abs_path('/dev/root')

for my $contentsFile (</var/db/pkg/*/*/CONTENTS>)
{
	open H, "<$contentsFile" or die;
	while (<H>)
	{
		if (/^dir (.*)$/)
		{
			$objects{abs_path($1)}->{directory} = 1;
		}
		if (/^obj (.*) [0-9a-f]{32} \d+$/)
		{
			$objects{abs_path($1)}->{file} = 1;
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
