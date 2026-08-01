#!/usr/bin/env perl
use strict;
use warnings;
use Errno qw(EEXIST ENOENT);
use Fcntl qw(O_DIRECTORY O_NOFOLLOW O_RDONLY);
use File::Basename qw(dirname);
use File::Spec;
use POSIX qw(S_ISDIR);

sub fail {
    my ($message) = @_;
    print STDERR "$message\n";
    exit 1;
}

sub open_directory {
    my ($path) = @_;
    sysopen(my $handle, $path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        or return;
    my @stat = stat($handle);
    return unless @stat && S_ISDIR($stat[2]);
    return $handle;
}

sub fd_child_path {
    my ($parent, $name) = @_;
    return '/proc/self/fd/' . fileno($parent) . "/$name";
}

sub same_directory {
    my ($left, $right) = @_;
    my @left_stat = stat($left);
    my @right_stat = stat($right);
    return @left_stat && @right_stat
        && $left_stat[0] == $right_stat[0]
        && $left_stat[1] == $right_stat[1];
}

sub prepare_child {
    my (%args) = @_;
    my $path = fd_child_path($args{parent}, $args{name});
    my $handle = open_directory($path);
    if (!$handle) {
        fail("required legacy managed directory is absent: $args{name}")
            if $args{must_exist};
        mkdir($path, $args{mode}) or do {
            fail("cannot create managed directory: $args{name}")
                unless $! == EEXIST;
        };
        $handle = open_directory($path);
    }
    fail("managed directory is linked or not a directory: $args{name}")
        unless $handle;

    my @stat = stat($handle);
    my %allowed = map { $_ => 1 } @{$args{allowed_uids}};
    fail("managed directory has unexpected ownership: $args{name}")
        unless $allowed{$stat[4]};

    chown($args{uid}, $args{gid}, $handle) == 1
        or fail("cannot set managed directory ownership: $args{name}");
    chmod($args{mode}, $handle) == 1
        or fail("cannot set managed directory mode: $args{name}");
    my $reopened = open_directory($path);
    fail("managed directory changed during preparation: $args{name}")
        unless $reopened && same_directory($handle, $reopened);
    return $handle;
}

sub self_bind_enabled {
    my ($home_root) = @_;
    return 0 unless $> == 0;
    return 1 if $home_root eq '/home';
    return ($ENV{VX_COMPOSE_TEST_MODE} // '') eq 'yes'
        && ($ENV{VX_COMPOSE_TEST_ALLOW_SELF_BIND} // '') eq 'yes';
}

sub is_mountpoint {
    my ($handle) = @_;
    return system('mountpoint', '-q', "/proc/$$/fd/" . fileno($handle)) == 0;
}

sub self_bind {
    my ($handle) = @_;
    my $path = "/proc/$$/fd/" . fileno($handle);
    return if is_mountpoint($handle);
    system('mount', '--bind', $path, $path) == 0
        or fail('cannot protect managed data root as a self-bind mount');
    is_mountpoint($handle)
        or fail('managed data root self-bind mount was not established');
}

sub self_unbind {
    my ($handle) = @_;
    return unless is_mountpoint($handle);
    my $path = "/proc/$$/fd/" . fileno($handle);
    system('umount', '--lazy', $path) == 0
        or fail('cannot release managed legacy data-root self-bind mount');
}

@ARGV == 5
    or fail('usage: managed-directory.pl OWNER HOMEDIR PROJECT LEAF MODE');
my ($owner, $home_root, $project, $leaf, $transition) = @ARGV;
$owner =~ /\A[a-z][a-z0-9_-]{0,31}\z/
    or fail('invalid managed directory owner');
$project eq '-' || $project =~ /\A[a-z][a-z0-9_-]{0,62}\z/
    or fail('invalid managed project');
$leaf eq '-' || $leaf =~ /\A[a-z0-9][a-z0-9_-]{0,63}\z/
    or fail('invalid managed bind leaf');
$transition eq 'normal' || $transition eq 'legacy'
    || $transition eq 'rollback' || $transition eq 'restore-rollback'
    || $transition eq 'unmount'
    or fail('invalid managed directory transition');
$leaf eq '-' || $project ne '-'
    or fail('managed bind leaf requires a project');
File::Spec->file_name_is_absolute($home_root)
    or fail('managed home root must be absolute');
$home_root eq File::Spec->canonpath($home_root)
    or fail('managed home root must be canonical');

my @owner_entry = getpwnam($owner);
@owner_entry or fail('managed directory owner does not exist');
my ($owner_uid, $owner_gid) = @owner_entry[2, 3];
my $authority_uid = $> == 0 ? 0 : $>;
if ($> != 0 && $owner_uid != $>) {
    fail('non-root managed directory preparation crossed owners');
}

my $home_root_handle = open_directory($home_root)
    or fail('managed home root is unavailable');
my $owner_home_path = fd_child_path($home_root_handle, $owner);
my $owner_home = open_directory($owner_home_path)
    or fail('managed owner home is linked or unavailable');
my @owner_home_stat = stat($owner_home);
fail('managed owner home has unexpected ownership')
    unless $owner_home_stat[4] == $owner_uid
        || $owner_home_stat[4] == $authority_uid;

my @authority_uids = ($authority_uid);
push @authority_uids, $owner_uid
    if $transition eq 'legacy' || $transition eq 'restore-rollback';
my $managed_uid = $transition eq 'rollback'
    || $transition eq 'restore-rollback' ? $owner_uid : $authority_uid;
my $docker_uid = $transition eq 'restore-rollback'
    ? $authority_uid : $managed_uid;
my @managed_uids = $transition eq 'rollback'
    ? ($authority_uid) : @authority_uids;
my @handles = ($home_root_handle, $owner_home);
my $docker = prepare_child(
    parent => $owner_home,
    name => 'docker',
    mode => 0750,
    uid => $docker_uid,
    gid => $owner_gid,
    allowed_uids => \@managed_uids,
    must_exist => $transition ne 'normal',
);
push @handles, $docker;

if (($ENV{VX_COMPOSE_TEST_MODE} // '') eq 'yes'
    && defined $ENV{VX_COMPOSE_TEST_MANAGED_DIRECTORY_PAUSE}) {
    my $pause = $ENV{VX_COMPOSE_TEST_MANAGED_DIRECTORY_PAUSE};
    $pause =~ m{\A/tmp/[A-Za-z0-9._/-]+\z}
        or fail('invalid managed-directory test pause path');
    open(my $ready, '>', "$pause.ready")
        or fail('cannot create managed-directory test ready marker');
    close($ready);
    my $continued = 0;
    for (1 .. 500) {
        if (-f "$pause.continue") {
            $continued = 1;
            last;
        }
        select(undef, undef, undef, 0.01);
    }
    unlink("$pause.ready", "$pause.continue");
    fail('managed-directory test pause timed out') unless $continued;
}

if ($project ne '-') {
    my $project_handle = prepare_child(
        parent => $docker,
        name => $project,
        mode => 0750,
        uid => $managed_uid,
        gid => $owner_gid,
        allowed_uids => \@managed_uids,
        must_exist => $transition ne 'normal',
    );
    push @handles, $project_handle;
    my $binds = prepare_child(
        parent => $project_handle,
        name => 'binds',
        mode => 0750,
        uid => $managed_uid,
        gid => $owner_gid,
        allowed_uids => \@managed_uids,
        must_exist => $transition eq 'rollback'
            || $transition eq 'restore-rollback',
    );
    push @handles, $binds;
    if ($leaf ne '-') {
        my @leaf_uids = ($authority_uid, $owner_uid);
        my $leaf_handle = prepare_child(
            parent => $binds,
            name => $leaf,
            mode => 0750,
            uid => $owner_uid,
            gid => $owner_gid,
            allowed_uids => \@leaf_uids,
            must_exist => 0,
        );
        push @handles, $leaf_handle;
    }
}

# Re-open the complete chain from every still-open parent descriptor. This
# detects a rename before returning without ever following a symlink.
my $parent = $owner_home;
for my $name ('docker', ($project ne '-' ? ($project, 'binds') : ()),
    ($leaf ne '-' ? ($leaf) : ())) {
    my $path = fd_child_path($parent, $name);
    my $reopened = open_directory($path)
        or fail("managed directory chain changed: $name");
    my ($expected) = grep {
        same_directory($_, $reopened)
    } @handles;
    fail("managed directory chain identity changed: $name") unless $expected;
    $parent = $reopened;
}

if (self_bind_enabled($home_root)) {
    if ($transition eq 'rollback' || $transition eq 'unmount') {
        undef $parent;
        for (my $index = $#handles; $index >= 3; $index--) {
            close($handles[$index]);
        }
        self_unbind($docker);
    } elsif ($transition eq 'restore-rollback') {
        # A restore transaction rolls back every project while the shared
        # owner root remains protected, then restores/unmounts that root once.
    } else {
        self_bind($docker);
    }
}

exit 0;
