package App::cpm::Worker::Installer;
use strict;
use warnings;
use utf8;
our $VERSION = '0.957';

use App::cpm::Logger::File;
use App::cpm::Worker::Installer::Menlo;
use App::cpm::Worker::Installer::Prebuilt;
use App::cpm::version;
use CPAN::DistnameInfo;
use CPAN::Meta;
use Config;
use ExtUtils::Install ();
use ExtUtils::InstallPaths ();
use File::Basename 'basename';
use File::Copy ();
use File::Copy::Recursive ();
use File::Path qw(mkpath rmtree);
use File::Spec;
use File::Temp ();
use File::pushd 'pushd';
use JSON::PP ();
use Time::HiRes ();

use constant NEED_INJECT_TOOLCHAIN_REQUIREMENTS => $] < 5.016;

my $TRUSTED_MIRROR = sub {
    my $uri = shift;
    !!( $uri =~ m{^https?://(?:www.cpan.org|backpan.perl.org|cpan.metacpan.org)} );
};

sub work {
    my ($self, $job) = @_;
    my $type = $job->{type} || "(undef)";
    local $self->{logger}{context} = $job->distvname;
    if ($type eq "fetch") {
        if (my $result = $self->fetch($job)) {
            return +{
                ok => 1,
                directory => $result->{directory},
                meta => $result->{meta},
                configure_requirements => $result->{configure_requirements},
                provides => $result->{provides},
                using_cache => $result->{using_cache},
                prebuilt => $result->{prebuilt},
                requirements => $result->{requirements},
            };
        } else {
            $self->{logger}->log("Failed to fetch/configure distribution");
        }
    } elsif ($type eq "configure") {
        # $job->{directory}, $job->{distfile}, $job->{meta});
        if (my $result = $self->configure($job)) {
            return +{
                ok => 1,
                distdata => $result->{distdata},
                requirements => $result->{requirements},
                static_builder => $result->{static_builder},
            };
        } else {
            $self->{logger}->log("Failed to configure distribution");
        }
    } elsif ($type eq "install") {
        my $ok = $self->install($job);
        my $message = $ok ? "Successfully installed distribution" : "Failed to install distribution";
        $self->{logger}->log($message);
        return { ok => $ok, directory => $job->{directory} };
    } else {
        die "Unknown type: $type\n";
    }
    return { ok => 0 };
}

sub new {
    my ($class, %option) = @_;
    $option{logger} ||= App::cpm::Logger::File->new;
    $option{base}  or die "base option is required\n";
    $option{cache} or die "cache option is required\n";
    mkpath $_ for grep !-d, $option{base}, $option{cache};
    $option{logger}->log("Work directory is $option{base}");

    my $menlo = App::cpm::Worker::Installer::Menlo->new(
        base => $option{base},
        logger => $option{logger},
        quiet => 1,
        pod2man => $option{man_pages},
        notest => $option{notest},
        sudo => $option{sudo},
        mirrors => ["https://cpan.metacpan.org/"], # this is dummy
        configure_timeout => $option{configure_timeout},
        build_timeout => $option{build_timeout},
        test_timeout => $option{test_timeout},
    );
    if ($option{local_lib}) {
        my $local_lib = $option{local_lib} = $menlo->maybe_abs($option{local_lib});
        $menlo->{self_contained} = 1;
        $menlo->log("Setup local::lib $local_lib");
        $menlo->setup_local_lib($local_lib);
    }
    $menlo->log("--", `$^X -V`, "--");
    $option{prebuilt} = App::cpm::Worker::Installer::Prebuilt->new if $option{prebuilt};
    bless { %option, menlo => $menlo }, $class;
}

sub menlo { shift->{menlo} }

sub _fetch_git {
    my ($self, $uri, $ref) = @_;
    my $basename = File::Basename::basename($uri);
    $basename =~ s/\.git$//;
    $basename =~ s/[^a-zA-Z0-9_.-]/-/g;
    my $dir = File::Temp::tempdir(
        "$basename-XXXXX",
        CLEANUP => 0,
        DIR => $self->menlo->{base},
    );
    $self->menlo->mask_output( diag_progress => "Cloning $uri" );
    $self->menlo->run_command([ 'git', 'clone', $uri, $dir ]);

    unless (-e "$dir/.git") {
        $self->menlo->diag_fail("Failed cloning git repository $uri", 1);
        return;
    }
    my $guard = pushd $dir;
    if ($ref) {
        unless ($self->menlo->run_command([ 'git', 'checkout', $ref ])) {
            $self->menlo->diag_fail("Failed to checkout '$ref' in git repository $uri\n");
            return;
        }
    }
    $self->menlo->diag_ok;
    chomp(my $rev = `git rev-parse --short HEAD`);
    ($dir, $rev);
}

sub enable_prebuilt {
    my $self = shift;
    my $uri = ref $_[0] ? $_[0][0] : $_[0];
    $self->{prebuilt} && !$self->{prebuilt}->skip($uri) && $TRUSTED_MIRROR->($uri);
}

sub fetch {
    my ($self, $job) = @_;
    my $guard = pushd;

    my $source   = $job->{source};
    my $distfile = $job->{distfile};
    my @uri      = ref $job->{uri} ? @{$job->{uri}} : ($job->{uri});

    if ($self->enable_prebuilt($uri[0])) {
        if (my $result = $self->find_prebuilt($uri[0])) {
            $self->{logger}->log("Using prebuilt $result->{directory}");
            return $result;
        }
    }

    my ($dir, $rev, $using_cache);
    if ($source eq "git") {
        for my $uri (@uri) {
            ($dir, $rev) = $self->_fetch_git($uri, $job->{ref});
            last if $dir;
        }
    } elsif ($source eq "local") {
        for my $uri (@uri) {
            $self->{logger}->log("Copying $uri");
            $uri =~ s{^file://}{};
            $uri = $self->menlo->maybe_abs($uri);
            my $basename = basename $uri;
            my $g = pushd $self->menlo->{base};
            if (-d $uri) {
                my $dest = File::Temp::tempdir(
                    "$basename-XXXXX",
                    CLEANUP => 0,
                    DIR => $self->menlo->{base},
                );
                File::Copy::Recursive::dircopy($uri, $dest);
                $dir = $dest;
                last;
            } elsif (-f $uri) {
                my $dest = $basename;
                File::Copy::copy($uri, $dest);
                $dir = $self->menlo->unpack($basename);
                $dir = File::Spec->catdir($self->menlo->{base}, $dir);
                last;
            }
        }
    } elsif ($source =~ /^(?:cpan|https?)$/) {
        my $g = pushd $self->menlo->{base};
        FETCH: for my $uri (@uri) {
            my $basename = basename $uri;
            if ($uri =~ s{^file://}{}) {
                $self->{logger}->log("Copying $uri");
                File::Copy::copy($uri, $basename)
                    or next FETCH;
                $dir = $self->menlo->unpack($basename)
                    or next FETCH;
                last FETCH;
            } else {
                local $self->menlo->{save_dists};
                if ($distfile and $TRUSTED_MIRROR->($uri)) {
                    my $cache = File::Spec->catfile($self->{cache}, "authors/id/$distfile");
                    if (-f $cache) {
                        $self->{logger}->log("Using cache $cache");
                        File::Copy::copy($cache, $basename);
                        $dir = $self->menlo->unpack($basename);
                        unless ($dir) {
                            unlink $cache;
                            next FETCH;
                        }
                        $using_cache++;
                        last FETCH;
                    } else {
                        $self->menlo->{save_dists} = $self->{cache};
                    }
                }
                $dir = $self->menlo->fetch_module({uris => [$uri], pathname => $distfile})
                    or next FETCH;
                last FETCH;
            }
        }
        $dir = File::Spec->catdir($self->menlo->{base}, $dir) if $dir;
    }
    return unless $dir;

    chdir $dir or die;

    my $meta = $self->_load_metafile($distfile, 'META.json', 'META.yml');
    if (!$meta) {
        $self->{logger}->log("Distribution does not have META.json nor META.yml");
        return;
    }
    my $p = $meta->{provides} || $self->menlo->extract_packages($meta, ".");
    my $provides = [ map +{ package => $_, version => $p->{$_}{version} }, sort keys %$p ];

    my $configure_requirements = [];
    if ($self->menlo->opts_in_static_install($meta)) {
        $self->{logger}->log("Distribution opts in x_static_install: $meta->{x_static_install}");
    } else {
        $configure_requirements = $self->_extract_configure_requirements($meta, $distfile);
    }

    return +{
        directory => $dir,
        meta => $meta,
        configure_requirements => $configure_requirements,
        provides => $provides,
        using_cache => $using_cache,
    };
}

sub find_prebuilt {
    my ($self, $uri) = @_;
    my $info = CPAN::DistnameInfo->new($uri);
    my $dir = File::Spec->catdir($self->{prebuilt_base}, $info->cpanid, $info->distvname);
    return unless -f File::Spec->catfile($dir, ".prebuilt");

    my $guard = pushd $dir;

    my $meta   = $self->_load_metafile($uri, 'META.json', 'META.yml');
    my $mymeta = $self->_load_metafile($uri, 'blib/meta/MYMETA.json');
    my $phase  = $self->{notest} ? [qw(build runtime)] : [qw(build test runtime)];
    my @req;
    if (!$self->menlo->opts_in_static_install($meta)) {
        # XXX Actually we don't need configure requirements for prebuilt.
        # But requires them for consistency for now.
        push @req, @{ $self->_extract_configure_requirements($meta, $uri) };
    }
    push @req, @{ $self->_extract_requirements($mymeta, $phase) };

    my $provides = do {
        open my $fh, "<", 'blib/meta/install.json' or die;
        my $json = JSON::PP::decode_json(do { local $/; <$fh> });
        my $provides = $json->{provides};
        [ map +{ package => $_, version => $provides->{$_}{version} || undef }, keys %$provides ];
    };
    return +{
        directory => $dir,
        meta => $meta->as_struct,
        provides => $provides,
        prebuilt => 1,
        requirements => \@req,
    };
}

sub save_prebuilt {
    my ($self, $job) = @_;
    my $dir = File::Spec->catdir($self->{prebuilt_base}, $job->cpanid, $job->distvname);

    if (-d $dir and !File::Path::rmtree($dir)) {
        return;
    }

    my $parent = File::Basename::dirname($dir);
    for (1..3) {
        last if -d $parent;
        eval { File::Path::mkpath($parent) };
    }
    return unless -d $parent;

    $self->{logger}->log("Saving the build $job->{directory} in $dir");
    if (File::Copy::Recursive::dircopy($job->{directory}, $dir)) {
        open my $fh, ">", File::Spec->catfile($dir, ".prebuilt") or die $!;
    } else {
        warn "dircopy $job->{directory} $dir: $!";
    }
}

sub _inject_toolchain_requirements {
    my ($self, $distfile, $reqs) = @_;
    $distfile ||= "";

    my %deps = map { $_->{package} => $_ } @$reqs;
    if (    -f "Makefile.PL"
        and !$deps{'ExtUtils::MakeMaker'}
        and !-f "Build.PL"
        and $distfile !~ m{/ExtUtils-MakeMaker-[0-9v]}
    ) {
        $deps{'ExtUtils::MakeMaker'} ||= { package => "ExtUtils::MakeMaker", version_range => 0 };
    }
    if ($deps{'Module::Build'}) {
        $deps{'ExtUtils::Install'} ||= { package => 'ExtUtils::Install', version_range => 0 };
    }

    my %inject = (
        'Module::Build' => '0.38',
        'ExtUtils::MakeMaker' => '6.58',
        'ExtUtils::Install' => '1.46',
    );

    for my $package (sort keys %inject) {
        my $inject = $inject{$package};
        my $dep = $deps{$package} or next;
        $dep->{version_range} = App::cpm::version::range_merge($dep->{version_range}, $inject);
    }

    @$reqs = values %deps;
}

sub _load_metafile {
    my ($self, $distfile, @file) = @_;
    my $meta;
    if (my ($file) = grep -f, @file) {
        $meta = eval { CPAN::Meta->load_file($file) };
        $self->{logger}->log("Invalid $file: $@") if $@;
    }

    if (!$meta and $distfile) {
        my $d = CPAN::DistnameInfo->new($distfile);
        $meta = CPAN::Meta->new({name => $d->dist, version => $d->version});
    }
    $meta;
}

# XXX Assume current directory is distribution directory
# because the test "-f Build.PL" or similar is present
sub _extract_configure_requirements {
    my ($self, $meta, $distfile) = @_;
    my $requirements = $self->_extract_requirements($meta, [qw(configure)]);
    if (!@$requirements and -f "Build.PL" and ($distfile || "") !~ m{/Module-Build-[0-9v]}) {
        push @$requirements, { package => "Module::Build", version_range => "0.38" };
    }
    if (NEED_INJECT_TOOLCHAIN_REQUIREMENTS) {
        $self->_inject_toolchain_requirements($distfile, $requirements);
    }
    return $requirements;
}

sub _extract_requirements {
    my ($self, $meta, $phases) = @_;
    $phases = [$phases] unless ref $phases;
    my $hash = $meta->effective_prereqs->as_string_hash;
    my @requirements;
    for my $phase (@$phases) {
        my $reqs = ($hash->{$phase} || +{})->{requires} || +{};
        for my $package (sort keys %$reqs) {
            push @requirements, {package => $package, version_range => $reqs->{$package}};
        }
    }
    \@requirements;
}

sub _retry {
    my ($self, $sub) = @_;
    return 1 if $sub->();
    return unless $self->{retry};
    Time::HiRes::sleep(0.1);
    $self->{logger}->log("! Retrying (you can turn off this behavior by --no-retry)");
    return $sub->();
}

sub configure {
    my ($self, $job) = @_;
    my ($dir, $distfile, $meta, $source) = @{$job}{qw(directory distfile meta source)};
    my $guard = pushd $dir;
    my $menlo = $self->menlo;

    $self->{logger}->log("Configuring distribution");
    my ($static_builder, $configure_ok);
    {
        if ($menlo->opts_in_static_install($meta)) {
            my $state = {};
            $menlo->static_install_configure($state, "dummy", 1);
            $static_builder = $state->{static_install};
            ++$configure_ok and last;
        }
        if (-f 'Build.PL') {
            $self->_retry(sub {
                $self->{logger}->log("Running Build.PL");
                $menlo->configure([ $menlo->{perl}, 'Build.PL' ], 1);
                -f 'Build';
            }) and ++$configure_ok and last;
        }
        if (-f 'Makefile.PL') {
            $self->_retry(sub {
                $self->{logger}->log("Running Makefile.PL");
                $menlo->configure([ $menlo->{perl}, 'Makefile.PL' ], 1); # XXX depth == 1?
                -f 'Makefile';
            }) and ++$configure_ok and last;
        }
    }
    return unless $configure_ok;

    my $distdata = $self->_build_distdata($source, $distfile, $meta);
    my $phase = $self->{notest} ? [qw(build runtime)] : [qw(build test runtime)];
    my $mymeta = $self->_load_metafile($distfile, 'MYMETA.json', 'MYMETA.yml');
    my $requirements = $self->_extract_requirements($mymeta, $phase);
    return +{
        distdata => $distdata,
        requirements => $requirements,
        static_builder => $static_builder,
    };
}

sub _build_distdata {
    my ($self, $source, $distfile, $meta) = @_;

    my $menlo = $self->menlo;
    my $fake_state = { configured_ok => 1, use_module_build => -f "Build" };
    my $module_name = $menlo->find_module_name($fake_state) || $meta->{name};
    $module_name =~ s/-/::/g;

    # XXX: if $source ne "cpan", then menlo->save_meta does nothing.
    # Moreover, if $distfile is git url, CPAN::DistnameInfo->distvname returns undef.
    # Then menlo->save_meta does nothing.
    my $distvname = CPAN::DistnameInfo->new($distfile)->distvname;
    my $provides = $meta->{provides} || $menlo->extract_packages($meta, ".");
    +{
        distvname => $distvname,
        pathname => $distfile,
        provides => $provides,
        version => $meta->{version} || 0,
        source => $source,
        module_name => $module_name,
    };
}

sub install {
    my ($self, $job) = @_;
    return $self->install_prebuilt($job) if $job->{prebuilt};

    my ($dir, $distdata, $static_builder) = @{$job}{qw(directory distdata static_builder)};
    my $guard = pushd $dir;
    my $menlo = $self->menlo;

    $self->{logger}->log("Building " . ($menlo->{notest} ? "" : "and testing ") . "distribution");
    my $installed;
    if ($static_builder) {
        $menlo->build(sub { $static_builder->build }, )
        && $menlo->test(sub { $static_builder->build("test") }, )
        && $menlo->install(sub { $static_builder->build("install") }, [])
        && $installed++;
    } elsif (-f 'Build') {
        $self->_retry(sub { $menlo->build([ $menlo->{perl}, "./Build" ], )  })
        && $self->_retry(sub { $menlo->test([ $menlo->{perl}, "./Build", "test" ], )  })
        && $self->_retry(sub { $menlo->install([ $menlo->{perl}, "./Build", "install" ], [])  })
        && $installed++;
    } else {
        $self->_retry(sub { $menlo->build([ $menlo->{make} ], )  })
        && $self->_retry(sub { $menlo->test([ $menlo->{make}, "test" ], )  })
        && $self->_retry(sub { $menlo->install([ $menlo->{make}, "install" ], []) })
        && $installed++;
    }

    if ($installed && $distdata) {
        $menlo->save_meta(
            $distdata->{module_name},
            $distdata,
            $distdata->{module_name},
        );
        $self->save_prebuilt($job) if $self->enable_prebuilt($job->{uri});
    }
    return $installed;
}

sub install_prebuilt {
    my ($self, $job) = @_;

    my $install_base = $self->{local_lib};
    if (!$install_base && ($ENV{PERL_MM_OPT} || '') =~ /INSTALL_BASE=(\S+)/) {
        $install_base = $1;
    }

    $self->{logger}->log("Copying prebuilt $job->{directory}/blib");
    my $guard = pushd $job->{directory};
    my $paths = ExtUtils::InstallPaths->new(
        dist_name => $job->distname, # this enables the installation of packlist
        $install_base ? (install_base => $install_base) : (),
    );
    my $install_base_meta = $install_base ? "$install_base/lib/perl5" : $Config{sitelibexp};
    my $distvname = $job->distvname;
    open my $fh, ">", \my $stdout;
    {
        local *STDOUT = $fh;
        ExtUtils::Install::install([
            from_to => $paths->install_map,
            verbose => 0,
            dry_run => 0,
            uninstall_shadows => 0,
            skip => undef,
            always_copy => 1,
            result => \my %result,
        ]);
        ExtUtils::Install::install({
            'blib/meta' => "$install_base_meta/$Config{archname}/.meta/$distvname",
        });
    }
    $self->{logger}->log($stdout);
    return 1;
}

1;
