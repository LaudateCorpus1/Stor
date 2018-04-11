package Stor;
use v5.20;

our $VERSION = '0.7.0';

use Mojo::Base -base, -signatures;
use Syntax::Keyword::Try;
use Path::Tiny;
use List::Util qw(shuffle min max sum);
use Mojo::Util qw(secure_compare);
use List::MoreUtils qw(first_index);
use Digest::SHA qw(sha256_hex);
use failures qw(stor stor::filenotfound);
use Safe::Isa;
use Guard qw(scope_guard);
use Time::HiRes qw(time);
use HTTP::Date;
use Net::Amazon::S3;

has 'storage_pairs';
has 'statsite';
has 'basic_auth';
has 'hcp_credentials';
has 'bucket' => sub ($self) {
    my $s3 = Net::Amazon::S3->new(
        {
            aws_access_key_id     => $self->hcp_credentials->{access_key},
            aws_secret_access_key => $self->hcp_credentials->{secret_key},
            host                  => $self->hcp_credentials->{host},
            secure                => 0,
            retry                 => 0,
            timeout               => 30
        }
    );
    return $s3->bucket('samples');
};

sub about ($self, $c) {
    $c->render(status => 200, text => "This is " . __PACKAGE__ . " $VERSION");
}

sub status ($self, $c) {
    for my $storage ($self->_get_shuffled_storages()) {
        die "Storage $storage isn't a directory"
            if !path($storage)->is_dir();

        my $mountpoint = qx(df --output=target $storage | tail -n 1);
        chomp $mountpoint;
        die "Storage $storage is not mounted"
            if $mountpoint eq '/';
    }

    $self->statsite->increment('healthcheck.count');

    $c->render(status => 200, text => 'OK');
}

sub get_from_old_storages ($self, $c, $sha) {
    my $tm_cache = time;
    my $path     = $c->chi->get($sha);
    $self->statsite->timing('cache.time', (time - $tm_cache) / 1000);
    if ($path) {
        $self->statsite->increment('cache.hit');
    }
    else {
        $self->statsite->increment('cache.miss');
        my $paths = $self->_lookup($sha);
        failure::stor::filenotfound->throw(
            {
                msg     => "File '$sha' not found",
                payload => { statsite_key => 'error.get.not_found_old.count' },
            }
        ) if !@$paths;

        $path = $paths->[0];
        $c->chi->set($sha => $path);
    }

    my $path_stat = $path->stat;
    $c->res->headers->content_length($path_stat->size);
    $c->res->headers->last_modified(time2str($path_stat->mtime));

    $self->_stream_found_file($c, $path);
    $self->statsite->increment('success.get.ok_old.count');
}

sub get_from_hcp ($self, $c, $sha) {
    my $hcp_key = $self->_sha_to_filepath($sha);

    my $resp = $self->bucket->get_key($hcp_key, 'HEAD');
    if (!$resp) {
        $self->statsite->increment('error.get.not_found_hcp.count');
        return 0;
    }

    $c->res->headers->content_length($resp->{content_length});
    $c->res->headers->last_modified($resp->{'last-modified'});

    my $count;
    $self->bucket->get_key_filename(
        $hcp_key, 'GET',
        sub {
            my ($chunk,) = @_;
            $c->write($chunk);
        }
    );
    $self->statsite->increment('success.get.ok_hcp.count');
    return 1;
}

sub get ($self, $c) {
    my $sha = $c->param('sha');
    try {
        failure::stor::filenotfound->throw({
            msg     => "Given hash '$sha' isn't SHA256",
            payload => { statsite_key => 'error.get.malformed_sha.count' },
        }) if $sha !~ /^[A-Fa-f0-9]{64}$/;


        if ($ENV{TEST} || !$self->get_from_hcp($c, $sha)) {
            $self->get_from_old_storages($c, $sha);
            #when you remove calling this function, add failure::stor::filenotfound
        }
    }
    catch {
        $c->app->log->debug("$@");
        if ($@->$_isa('failure::stor::filenotfound')) {
            $c->render(status => 404, text => "$@");
        }
        else {
            $self->statsite->increment('error.get.500.count');
            $c->render(status => 500, text => "$@");
        }
    }
    finally {
        if ($@->$_isa('failure::stor')) {
            $self->statsite->increment($@->payload->{statsite_key});
        }
    }
}

sub post ($self, $c) {
    my $sha  = $c->param('sha');

    if ($sha !~ /^[A-Fa-f0-9]{64}$/) {
        $self->statsite->increment('error.post.malformed_sha.count');
        $c->render(status => 412, text => "Given hash '$sha' isn't sha256");
        return
    }

    if (!$c->req->url->to_abs->userinfo || !secure_compare($c->req->url->to_abs->userinfo, $self->basic_auth)) {
        # Require authentication
        $c->res->headers->www_authenticate('Basic');
        $c->render(text => 'Authentication required!', status => 401);
        return
    }

    if (my @paths = @{$self->_lookup($sha, 1)}) {
        $self->statsite->increment('success.post.duplicate.count');
        $c->render(status => 200, json => \@paths);
        return
    }

    my $file = $c->req->content->asset;
    my $content_sha = sha256_hex($file->slurp());
    if ($sha ne $content_sha) {
        $self->statsite->increment('error.post.bad_sha.count');
        $c->render(status => 412, text =>
            "Content sha256 $content_sha doesn't match given sha256 $sha");
        return
    }

    try {
        my $storage_pair = $self->pick_storage_pair_for_file($file);
        my $paths = $self->save_file($file, $sha, $storage_pair);
        $self->statsite->increment('success.post.write.count');
        $c->render(status => 201, json => $paths);
    }
    catch {
        if ($@->$_isa('failure::stor')) {
            $self->statsite->increment($@->payload->{statsite_key});
            $c->render(status => 507, text => "$@");
            return
        }
        $self->statsite->increment('error.post.unknown.count');
        $c->render(status => 500, text => "$@");
        return
    }
}

sub pick_storage_pair_for_file ($self, $file) {
    my @free_space = map {$_ - $file->size()}
                        @{ $self->get_storages_free_space() };

    failure::stor->throw({
        msg => 'Not enough space on storages',
        payload => { statsite_key => 'error.post.no_space.count' },
    })
        if !grep {$_ > 0} @free_space;

    my $index = 0;
    if (!grep {$_ > 1_000_000_000} @free_space) {
        # we are short on space, pick the storage with most space
        $index = first_index {$_ == max(@free_space)} @free_space;
    }
    else {
        # there are several having enough space
        # pick randomly transforming space to probabilities
        my @probabilities = map { $_ / sum(@free_space) } @free_space;
        my $random = rand();

        my $cumulative_probability = 0;
        for my $prob (@probabilities) {
            $cumulative_probability += $prob;
            last if $random < $cumulative_probability;
            $index++
        }
    }

    return $self->storage_pairs->[$index]
}

sub get_storages_free_space($self) {
    my @free_space = map {min map {$self->get_storage_free_space($_)} @$_}
                        @{$self->storage_pairs};

    return \@free_space
}

sub get_storage_free_space($self, $storage) {
    return int(qx(df --output=avail $storage | tail -n 1))
}

sub save_file ($self, $file, $sha, $storage_pair) {
    my @all_paths = map { path($_, $self->_path_with_dat($sha)) } @$storage_pair;
    my @paths = @all_paths;
    $_->parent->mkpath() for @paths;
    my $first_path = shift @paths;
    $file->move_to($first_path);
    $first_path->copy($_) for @paths;
    return \@all_paths;
}

sub _lookup ($self, $sha, $return_all_paths = '') {
    my @paths;
    my $attempt = 0;
    my $tm_start = time;

    scope_guard {
        $self->statsite->timing('lookup.time', (time - $tm_start) / 1000);
        $self->statsite->increment("lookup.attempt.$attempt.count");
    };

    for my $storage ($self->_get_shuffled_storages()) {
        $attempt++;
        my $file_path = path($storage, $self->_path_with_dat($sha));
        if ($file_path->is_file) {
            push @paths, $file_path;
            return \@paths if !$return_all_paths
        }
    }

    return \@paths
}

sub _path_with_dat($self, $sha) {
    return uc($self->_sha_to_filepath($sha)) . '.dat';
}

sub _sha_to_filepath($self, $sha) {
    my $filename = lc($sha);
    my @subdir = unpack 'A2A2A2', $filename;

    return join '/', @subdir, $filename
}


sub _stream_found_file($self, $c, $path) {
    my $fh = $path->openr_raw();
    my $drain; $drain = sub {
        my ($c) = @_;

        my $chunk;
        my $tm_chunk = time;
        my $size = read($fh, $chunk, 1024 * 1024);
        if ($size == 0) {
            close($fh);
            $drain = undef;
        }

        $c->write($chunk, $drain);
        $self->statsite->update('success.get.ok.size', $size);
        $self->statsite->timing('success.get.ok.time', (time - $tm_chunk) / 1000);
    };
    $c->$drain;
}

sub _get_shuffled_storages($self) {

    my (@storages1, @storages2);
    for my $pair (shuffle @{$self->storage_pairs}) {
        my $rand = int(rand(2));
        push @storages1, $pair->[$rand];
        push @storages2, $pair->[1 - $rand];
    }

    return @storages1, @storages2
}


1;
__END__


=encoding utf-8

=head1 NAME

Stor - Save/retrieve a file to/from primary storage

=head1 SYNOPSIS

    # retrieve a file
    curl http://stor-url/946a5ec1d49e0d7825489b1258476fdd66a3e9370cc406c2981a4dc3cd7f4e4f

    # store a file
    curl -X POST --data-binary @my_file http://user:pass@stor-url/946a5ec1d49e0d7825489b1258476fdd66a3e9370cc406c2981a4dc3cd7f4e4f

=head1 DESCRIPTION

Stor is an HTTP API to primary storage. You provide a SHA256 hash and get the file contents, or you provide a SHA256 hash and a file contents and it gets stored to primary storages.

=head2 Service Responsibility

=over

=item provide HTTP API

=item redundancy support

=item resource allocation

=back

=head2 API

=head3 HEAD /:sha

=head3 GET /:sha

=head4 200 OK

File exists

Headers:

    Content-Length - file size of file

GET return content of file in body

=head4 404 Not Found

Sample not found


=head3 POST /:sha

save sample to n-tuple of storages

For authentication use Basic access authentication

compare SHA and sha256 of file

=head4 200 OK

file exists

Headers:

Body:

    {
        "locations": {
            "nfs":  ["server1:/some_path/to/file", "server2:/another_path/to/file"],
            "cifs": ["\\\\server1\\share\\path\\to\\file", "\\\\server2\\share\\path\\to\\file"]
        }
    }

=head4 201 Created

file was added to all storages

Body:

    {
        "locations": {
            "nfs":  ["server1:/some_path/to/file", "server2:/another_path/to/file"],
            "cifs": ["\\\\server1\\share\\path\\to\\file", "\\\\server2\\share\\path\\to\\file"]
        }
    }

=head4 401 Unauthorized

Bad authentication

=head4 412 Precondition Failed

content mismatch - sha256 of content not equal SHA

=head4 507 Insufficient Storage

There is not enough space on storage to save the file.

Headers:

    Content-Sha-256 - sha256 of content


=head3 GET /status

=head4 200 OK

all storages are available

=head4 503

some storage is unavailable

=head3 GET /storages

return list of storages and disk usage

=head2 Redundancy Support

for redundancy we need support defined n-tuple of storages

n-tuple of storages must works minimal 1 for GET and all for POST

pseudo-example of n-tuple of storages definition:

    [
        ["storage1", "storage2"],
        ["storage3", "storage4"]
    ]

in pseudo-example case we must new sample save to storage1 and storage2 or storage3 and storage4

=head2 Resource Allocation

save samples to n-tuple of storages with enough of resources => service responsibility is check disk usage

nice to have is balanced samples to all storages equally



=head1 LICENSE

Copyright (C) Avast Software

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Miroslav Tynovsky E<lt>tynovsky@avast.comE<gt>

=cut

