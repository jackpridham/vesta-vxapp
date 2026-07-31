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
push @authority_uids, $owner_uid if $transition eq 'legacy';
my @handles = ($home_root_handle, $owner_home);
my $docker = prepare_child(
    parent => $owner_home,
    name => 'docker',
    mode => 0750,
    uid => $authority_uid,
    gid => $owner_gid,
    allowed_uids => \@authority_uids,
    must_exist => $transition eq 'legacy',
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
        uid => $authority_uid,
        gid => $owner_gid,
        allowed_uids => \@authority_uids,
        must_exist => $transition eq 'legacy',
    );
    push @handles, $project_handle;
    my $binds = prepare_child(
        parent => $project_handle,
        name => 'binds',
        mode => 0750,
        uid => $authority_uid,
        gid => $owner_gid,
        allowed_uids => \@authority_uids,
        must_exist => 0,
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

exit 0;
