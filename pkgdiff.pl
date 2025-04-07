#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';
use POSIX ":sys_wait_h";
use lib './lib/';
use Data::Dumper;

use PkgDiff;

my $ssh_identity = "$ENV{HOME}/.ssh/id_ed25519";

my $pkgd1 = PkgDiff->new(
    hostname        => 'amendes',
    port            => 23000,
    user            => 'root',
    pkgmgr          => 'dnf',
    identity_files  => [ $ssh_identity ]
);

my $pkgd2 = PkgDiff->new(
    hostname        => 'dreamspace',
    port            => 23000,
    user            => 'ansible',
    pkgmgr          => 'apt',
    identity_files  => [ $ssh_identity ]
);

# Errors. would be nice but not necessary.
#
# my $forks = 0;
# for ( ($pkgd1, $pkgd2) ) {
#     my $pid = fork();
# 
#     unless (defined $pid) {
#         print STDERR "Could not fork.";
#         exit 1;
#     }
# 
#     if ($pid) { $forks++; }
#     else {
#         $_->test_ssh_connection();
#         exit;
#     }
# 
#     waitpid($pid, WNOHANG);     # non blocking wait
# }
# 
# foreach my $i (1..$forks) {
#     my $pid = wait();
#     say "fork $i done";
# }

$pkgd1->test_ssh_connection;
$pkgd2->test_ssh_connection;

foreach my $host ( ($pkgd1, $pkgd2) ) {
    unless ($host->connection_success) {
        say for @{$host->get_errors};
        die "ssh connection to $host->{hostname} failed" if $host->connection_success == 0;
    }
}

say "Connections succeeded";
say "Getting packages";
$pkgd1->get_pkgs;
# $pkgd1->print_self();
$pkgd2->get_pkgs;
# $pkgd2->print_self();

foreach my $pkgd ( ($pkgd1, $pkgd2) ) {
    if ($pkgd->has_errors) {
        say "Errors for host $pkgd->{hostname}:";
        print Dumper $pkgd->get_errors;
        exit 1;
    }
}

my $differ = PkgDiff::Differ->new(
    host1   => $pkgd1,
    host2   => $pkgd2,
    filters => [qw /
        ^(perl|sed|gawk|vim|vim-common|vim-enhanced)[^-]
    /]
);

$differ->diff();
