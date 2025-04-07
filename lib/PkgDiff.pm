package PkgDiff;

use strict;
use warnings;
use Net::SSH::Perl;
use Carp qw / croak /;
use Data::Dumper;

sub new {
    my ($class, %cnf) = @_;
    my $hostname = delete $cnf{hostname};
    my $port = delete $cnf{port};
    if (defined $port) {
        croak "port must be integer" unless $port =~ m/^\d+$/;
    }
    $port = 22 unless defined $port;
    my $user = delete $cnf{user};
    my $pkgmgr = delete $cnf{pkgmgr};
    my $ssh_opts = delete $cnf{ssh_opts};
    my $identity_files = delete $cnf{identity_files};

    my $self = bless {
        hostname        => $hostname,
        port            => $port,
        user            => $user,
        pkgmgr          => $pkgmgr,
        identity_files  => $identity_files,
        connect_success => 0,
        ssh_obj         => undef,
        ssh_opts        => $ssh_opts,
        pkgs            => undef,
        errors          => []
    }, $class;
}

sub print_self {
    my $self = shift;
    print Dumper $self;
}

sub connection_success {
    my $self = shift;
    return $self->{connect_success};
}

sub has_errors {
    my $self = shift;
    return scalar(@{$self->{errors}}) > 0 ? 1 : 0;
}

sub get_errors {
    my $self = shift;
    return $self->{errors};
}

sub test_ssh_connection {
    my $self = shift;

    eval {
        $self->{ssh_obj} = Net::SSH::Perl->new(
            $self->{hostname},
            port            => $self->{port},
            identity_files  => $self->{identity_files}
        );
        1;
    } or do {
        push @{$self->{errors}}, map { chomp;+$_; } $@;
        $self->{connect_success} = 0;
        return 0;
    };

    $self->{connect_success} = 1;
    return 1;
}

sub get_pkgs {
    my $self = shift;
    my $pkgmgr = PkgDiff::PkgMgr->new(
        pkgmgr         => $self->{pkgmgr},
        user           => $self->{user},
        ssh_obj        => $self->{ssh_obj},
        errors         => $self->{errors}
    );
    my @pkgs = $pkgmgr->get_pkgs;
    push @{$self->{errors}}, map { chomp;+$_; } @{$pkgmgr->get_errors} if $pkgmgr->has_errors;
    $self->{pkgs} = \@pkgs;
}

1;
#### package PkgDiff END #######################################################

package PkgDiff::PkgMgr;

use strict;
use warnings;
use Carp qw / croak /;
use Data::Dumper;

sub new {
    my ($class, %cnf) = @_;
    my $pkg_mgr = delete $cnf{pkgmgr} || croak "Missing parameter pkgmgr";
    my $ssh_obj = delete $cnf{ssh_obj};
    my $user = delete $cnf{user};
    my $list_cmd;

    if (grep { /^$pkg_mgr$/ } qw / 
        dnf
        yum
        rpm
        /) {
        $pkg_mgr = "rpm";
        $list_cmd = 'rpm -qa --qf "%{NAME}\t %{VERSION}-%{RELEASE}\t %{ARCH}\t %{SUMMARY}\n"';
    }
    elsif (grep { /^$pkg_mgr$/ } qw /
        apt
        apt-get
        aptitude
        dpkg
        /) {
        $pkg_mgr = "dpkg";
        $list_cmd = "dpkg -l";
    }
    else {
        croak "Package manager $pkg_mgr unknown.";
    }

    my $self = bless {
        pkg_mgr         => $pkg_mgr,
        list_cmd        => $list_cmd,
        ssh_obj         => $ssh_obj,
        user            => $user,
        errors          => []
    }, $class;
}

sub get_pkgs {
    my $self = shift;
    if ($self->{pkg_mgr} eq "rpm") {
        $self->get_pkgs_rpm;
    }
    elsif ($self->{pkg_mgr} eq "dpkg") {
        $self->get_pkgs_dpkg;
    }
}

sub has_errors {
    my $self = shift;
    return scalar(@{$self->{errors}}) > 0 ? 1 : 0;
}

sub get_errors {
    my $self = shift;
    return $self->{errors};
}

sub get_pkgs_rpm {
    my $self = shift;
    eval {
        $self->{ssh_obj}->login($self->{user});
        1;
    } or do {
        push @{$self->{errors}}, "Could not login user $self->{user}";
        push @{$self->{errors}}, map { chomp;+$_; } $@;
        return ();
    };
    my ($stdout, $stderr, $exit) = $self->{ssh_obj}->cmd($self->{list_cmd});
    my @output = split /\n/, $stdout;
    return
        sort
        @output
}

sub get_pkgs_dpkg {
    my $self = shift;
    eval {
        $self->{ssh_obj}->login($self->{user});
        1;
    } or do {
        push @{$self->{errors}}, "Could not login user $self->{user}";
        push @{$self->{errors}}, map { chomp;+$_; } $@;
        return ();
    };
    my ($stdout, $stderr, $exit) = $self->{ssh_obj}->cmd($self->{list_cmd});
    my @output = split /\n/, $stdout;
    return
        sort
        map { s/^ii\s+(.*$)/$1/;+$_; }
        grep { /^ii/ }
        @output
}

1;
#### package PkgDiff::PkgMgr END ###############################################

package PkgDiff::Differ;

use strict;
use warnings;
use Carp qw / croak /;
use Data::Dumper;

sub new {
    my ($class, %cnf) = @_;
    my $required_type = "PkgDiff";

    my $host1 = delete $cnf{host1} or croak "Missing parameter host1";
    my $host2 = delete $cnf{host2} or croak "Missing parameter host2";
    my $filters = delete $cnf{filters};
    if (defined $filters) {
        croak "filters must be an array ref" unless ref $filters eq "ARRAY";
    }

    map {
        croak "Parameter must be of type PkgDiff" unless ref $_ eq $required_type;
    }
    ($host1, $host2);

    my $self = bless {
        host1   => $host1,
        host2   => $host2,
        filters => $filters
    }, $class;
}

sub diff {
    my $self = shift;

    my @packages1 = $self->diff_map($self->{host1}->{pkgs});
    my @packages2 = $self->diff_map($self->{host2}->{pkgs});

    print $self->{host1}->{hostname} . ":\n";
    print Dumper \@packages1;
    print $self->{host2}->{hostname} . ":\n";
    print Dumper \@packages2;
    print "Host1: " . scalar(@packages1) . "\n";
    print "Host2: " . scalar(@packages2) . "\n";
}

sub diff_map {
    my ($self, $pkgs) = @_;
    my @g_filters = defined $self->{filters} ? @{$self->{filters}} : ();
    return
        map {
            /^(.+?)(:.+?)?\s+(.+?)\s+(.+?)\s+(.*)$/;
            +{
                name        => $1,
                version     => $3,
                arch        => $4,
                description => $5
            }
        }
        grep { 
            if (scalar(@g_filters) > 0) {
                # my $str = $_; grep { $str =~/\Q$_/i } @g_filters
                my $str = $_; grep { $str =~/$_/i } @g_filters
            }
            else {
                //;
            }
        }
        @{$pkgs};
}

1;
#### PkgDiff::Differ END #######################################################

__END__
=pod

=head1 NAME

PkgDiff - A package for comparing package lists between two linux hosts

=head1 SYNOPSIS

    use PkgDiff;
    use PkgDiff::PkgMgr;
    use PkgDiff::Differ;

    # Create PkgDiff objects for two hosts
    my $host1 = PkgDiff->new(
        hostname        => 'host1.example.com',
        port            => 22,
        user            => 'username',
        pkgmgr          => 'yum',
        identity_files  => ['/path/to/id_rsa']
    );

    my $host2 = PkgDiff->new(
        hostname        => 'host2.example.com',
        port            => 22,
        user            => 'username',
        pkgmgr          => 'apt',
        identity_files  => ['/path/to/id_rsa']
    );

    # Test SSH connections
    $host1->test_ssh_connection();
    $host2->test_ssh_connection();

    # Get package lists
    $host1->get_pkgs();
    $host2->get_pkgs();

    # Create a Differ object and compare packages
    my $differ = PkgDiff::Differ->new(
        host1   => $host1,
        host2   => $host2,
        filters => ['kernel', 'bash']
    );

    $differ->diff();

=head1 DESCRIPTION

PkgDiff is a Perl module designed to compare package lists between two hosts. It uses SSH to connect to the hosts and retrieve package information using the specified package manager.

The module consists of three main classes:

=over 4

=item * L<PkgDiff>

The main class that handles the connection to a host and retrieves package information.

=item * L<PkgDiff::PkgMgr>

A helper class that interacts with different package managers to retrieve package lists.

=item * L<PkgDiff::Differ>

A class that compares package lists between two hosts and displays the differences.

=back

=head1 CLASSES

=head2 PkgDiff

=over 4

=item new(%cnf)

Constructor for PkgDiff objects. Takes a hash of configuration options:

=over 4

=item hostname

The hostname or IP address of the target host.

=item port

The SSH port to use (default: 22).

=item user

The username to use for SSH connection.

=item pkgmgr

The package manager to use (e.g., 'yum', 'apt', 'dnf', etc.).

=item ssh_opts

Additional SSH options.

=item identity_files

An array reference of paths to SSH identity files.

=back

=item print_self()

Prints the internal state of the object using Data::Dumper.

=item connection_success()

Returns a boolean indicating whether the SSH connection was successful.

=item has_errors()

Returns a boolean indicating whether there are any errors.

=item get_errors()

Returns an array reference of error messages.

=item test_ssh_connection()

Tests the SSH connection to the host and returns a boolean indicating success.

=item get_pkgs()

Retrieves the package list from the host using the specified package manager.

=back

=head2 PkgDiff::PkgMgr

=over 4

=item new(%cnf)

Constructor for PkgDiff::PkgMgr objects. Takes a hash of configuration options:

=over 4

=item pkgmgr

The package manager to use (e.g., 'yum', 'apt', 'dnf', etc.).

=item ssh_obj

The Net::SSH::Perl object to use for SSH connections.

=item user

The username to use for SSH connection.

=back

=item get_pkgs()

Retrieves the package list using the appropriate command for the specified package manager.

=item has_errors()

Returns a boolean indicating whether there are any errors.

=item get_errors()

Returns an array reference of error messages.

=item get_pkgs_rpm()

Retrieves the package list for RPM-based systems.

=item get_pkgs_dpkg()

Retrieves the package list for Debian-based systems.

=back

=head2 PkgDiff::Differ

=over 4

=item new(%cnf)

Constructor for PkgDiff::Differ objects. Takes a hash of configuration options:

=over 4

=item host1

A PkgDiff object representing the first host.

=item host2

A PkgDiff object representing the second host.

=item filters

An array reference of package name filters to apply during comparison.

=back

=item diff()

Compares the package lists between the two hosts and displays the results.

=item diff_map($pkgs)

Maps the package list to a standardized format and applies filters if specified.

=back

=head1 DEPENDENCIES

=over 4

=item * Net::SSH::Perl

=item * Carp

=item * Data::Dumper

=back

=head1 AUTHOR

Albert J. Mendes <tray.mendes@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2025 by Albert J. Mendes.

This is free software; you can redistribute it and/or modify it under the same terms as the Perl 5 programming language system itself.

=cut
