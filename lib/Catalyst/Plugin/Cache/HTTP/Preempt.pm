use utf8;
package Catalyst::Plugin::Cache::HTTP::Preempt;

use v5.10;

use strict;
use warnings;

use Moose::Role;

use Catalyst::Utils;
use DateTime;
use English qw( -no_match_vars );
use HTTP::Status qw( :constants );
use HTTP::Headers::ETag;
use List::Util ();
use Readonly;

Readonly::Scalar my $CONFIG_NAMESPACE => 'Plugin::Cache::HTTP::Preempt';

=head1 NAME

Catalyst::Plugin::Cache::HTTP::Preempt - preemptive HTTP cache control

=begin readme

=head1 VERSION

v0.1.0

=head1 REQUIREMENTS

This module requires Perl v5.10 or later.

The following non-core Perl modules are required:

=over 4

=item Catalyst

=item DateTime

=item DateTime::Format::HTTP

=item HTTP::Message 6.06

=item Moose

=item Readonly

=item Test::WWW::Mechanize::Catalyst

=back

=end readme

=cut

use version 0.77; our $VERSION = version->declare("v0.1.2");

=head1 DESCRIPTION

This is a L<Catalyst> plugin handles HTTP 1.1 cache-control queries.

The functionality is similar to L<Catalyst::Plugin::Cache::HTTP>,
except that it processes the cache control queries before
data-intensive queries, rather rather than delaying processing until
the view is generated.

=head1 SYNOPSIS

  use Catalyst qw/
    Cache::HTTP::Preempt
  /;

  __PACKAGE__->config(

    'Plugin::Cache::HTTP::Preempt' => {

       no_preempt_head => 0,

       etag_generator => sub {
         my ($c, $config) = @_;
         return "W/" . sprintf("%x", $c->res->headers->last_modified);
       },

    },

  );

=head1 CONFIGURATION OPTIONS

=over

=item no_preempt_head

By default, the L</not_cached> method will return C<false> for
C<HEAD> requests (even though it will still process cache control
headers).

If you still want to handle C<HEAD> requests, then set this option to
a C<true> value.

=item no_etag

Do not set the C<ETag> header.

=item no_last_modified

Do not set the C<Last-Modified> header.

=item no_expires

Do not set the C<Expires> header.

=item etag_generator

You can change how the C<ETag> is generated by using the
C<etag_generator> option:

  sub etag_generator {
      my ($c, $config) = @_;
      my $mtime = $c->req->headers->last_modified;
      return sprintf( $config->{strong} ? "%x" : "W/%x" , $mtime);
  }

  if ($c->not_cached({ etag_generator => \&etag_generator }) {
    ...
  }

This is useful if you want to use something other than the
modification date of an entity for generating the C<ETag>.

The purpose of this function is to I<only> generate the C<ETag>. No
headers should be changed.

Returning an C<undef> value corresponds to not setting an C<ETag>.

=item strong

Generate a strong C<ETag>. By default, a weak C<ETag> is used, since
the C<ETag> is based on the C<Last-Modified> time rather than the
content.

As per the HTTP 1.1 specification, weak C<ETags> will not work with
the C<If-Match> header.

=item check_if_range

When this option, is true, it will check for the C<If-Range> and
C<Range> headers.  The controller is responsible for sending the
correct response. (See the discussion for the L</not_cached> method
below.)

=back

=head1 METHODS

=cut


=head2 not_cached

  $c->res->headers->last_modified( $obj->mtime );

  ...

  if ($c->not_cached(\%options)) {

     # The response is not cached, so should be generated

     ...

   } else {

     ...

   }

Checks the requests for HTTP 1.1 cache control headers and handles
them accordingly.

This method sets the C<ETag> header based on the C<Last-Modified>
header (unless one is already set) and checks for the
C<If-Modified-Since>, C<If-Unmodified-Since>, C<If-Match> and
C<If-None-Match> request headers to see if generating the entity can
be preempted.

If the entity can be preempted (i.e. if it has not been modified since
the given date), then the status is set appropriately, and this
method returns false.

Otherwise it returns true.  This allows you to avoid reading data from
a database or otherwise data-intensive processing when it's not
actually needed.

If C<%options> are given, then they will override the L<global
options|/CONFIGURATION OPTIONS>.

If the C<Last-Modified> header is unset, then this function
will assume the last-modification time is the current time.

If no C<Expires> header is set and the function will return a true
value, then it will set it to the current time.  (This is important
for web browsers that aggressively cache responses, such as Firefox.)

Cache control options will be processed for C<HEAD> requests, but this
method will always return false, unless the C<no_preempt_head> option
is true.

If the status is already set to something other than C<2xx> when this
method is called, then the the C<If-Match>, C<If-None-Match> and
C<If-Unmodified-Since> headers will be ignored.  However, the C<ETag>,
C<Expires> and C<Last-Modified> headers will still be set.  (Ideally,
you would not be calling the L</not_cached> method if there is an
error.)

If the C<check_if_range> option is true, then you I<must> check
whether the status code has been set to C<206> or C<200>, and respond
accordingly:

    if ($c->not_cached( { check_if_range => 1 }) {

      if ($c->res->code == 206) {

        # Return partial content as per the Range header.

        ...


      } else {

        # Return full content. Note that the status is set to 200, so
        # it must be updated if there are other errors

        ...

      }

    }


=cut

sub not_cached {
    my ($self, $opts) = @ARG;

    my $config = Catalyst::Utils::merge_hashes(
	$self->config->{$CONFIG_NAMESPACE} // { },
	$opts // { });

    my $req_h  = $self->req->headers;
    my $res_h  = $self->res->headers;

    my $method = $self->req->method;

    my $current_time  = time;

    unless ($config->{no_last_modified} || (defined $res_h->last_modified)) {
	$res_h->last_modified($current_time);
    }

    my $last_modified = $res_h->last_modified;

    my $generator = $config->{etag_generator} // sub {
	my ($c, $config) = @ARG;
	return sprintf( $config->{strong} ? "%x" : "W/%x" , $last_modified);
    };

    unless ($res_h->etag || $config->{no_etag}) {
	$res_h->etag( &{$generator}($self, $config) );
    }

    my $etag    = $res_h->etag;
    my $is_weak = (substr($etag, 0, 2) eq 'W/');

    # We check to see if the status is set, and if so, ignore headers
    # as specified in HTTP 1.1 specification.

    my $status    = $self->res->code;
    my $no_ignore = (!$status) || ($status =~ /^2\d\d$/);

    # This code largely follows what Plugin::Cache::HTTP does

    if ($no_ignore && (my @checks = $req_h->if_match)) {

	my $match = $is_weak ? undef :
	    List::Util::first { ($ARG eq '"*"') || ($ARG eq $etag) } @checks;

	unless (defined $match) {

	    $self->log->debug("No Match") if ($self->debug);

	    $self->res->status(HTTP_PRECONDITION_FAILED);

	    return 0;

	}

    }

    elsif ($no_ignore && ($ARG = $req_h->if_unmodified_since) && ($ARG < $last_modified)) {

	$self->log->debug("Modified Since") if ($self->debug);

	$self->res->status(HTTP_PRECONDITION_FAILED);

	return 0;

    }

    elsif ($no_ignore && (@checks = $req_h->if_none_match)) {

	my $match =
	    List::Util::first { ($ARG eq '"*"') || ($ARG eq $etag) } @checks;

	if (defined $match) {

	    $self->log->debug("Match") if ($self->debug);

	    # The HTTP 1.1 specification is inconsistent here. In
	    # 13.3.3 is says that weak validation may only be used for
	    # GET requests, but in 14.26 it says that weak comparison
	    # can be used for GET or HEAD requests.

	    if (($method eq 'GET') || ($method eq 'HEAD')) {
		$self->res->status(HTTP_NOT_MODIFIED);
		return 0;
	    } elsif (!$is_weak) {
		$self->res->status(HTTP_PRECONDITION_FAILED);
		return 0;
	    }

	}

    }

    elsif (($ARG = $req_h->if_modified_since) && ($ARG <= $last_modified)) {

	$self->log->debug("Not Modified Since") if ($self->debug);

	# Note: the controller is expected to check for range handlers
	# and process them appropriately.

	unless ($req_h->header('Range')) {

	    $self->res->status(HTTP_NOT_MODIFIED);

	    return 0;

	}

    }

    elsif ((my @check = $req_h->if_range) && ($req_h->range) && $config->{check_if_range}) {

	my $match =
	    List::Util::first {
		(($ARG =~ /^\d+$/) && ($ARG >= $last_modified)) || ($ARG eq '"*"') || ($ARG eq $etag)
	} @checks;

	$self->res->status( (defined $match) ? HTTP_PARTIAL_CONTENT : HTTP_OK );

    }

    # The expiration time is only set when not_cached if true.

    unless ($config->{no_expires} || (defined $res_h->expires)) {
	$res_h->expires( $current_time );
    }

    if ($method eq 'HEAD') {
	return ($config->{no_preempt_head} || 0);
    }

    return 1;
}

=head1 Using with Catalyst::Plugin::Cache::HTTP

This module can be used with L<Catalyst::Plugin::Cache::HTTP> in a
L<Catalyst> application, although it is not recommended that you use
it in the same method.

If you are using both plugins, then you should modify the view
processing method to check if an C<ETag> header has already been set:

  sub process {
    my $self = shift;
    my $c = $_[0];

    $self->next::method(@_)
        or return 0;

    my $method = $c->req->method;
    return 1
        if ((($method ne 'GET') and ($method ne 'HEAD'))
            or $c->stash->{nocache}); # disable caching explicitely

    unless ($c->res->headers->etag || $c->stash->{no_etag}) {
      ...
    }

  }

=head1 Using with Catalyst::Controller::REST

L<Catalyst::Controller::REST> does not have status helpers for
"304 Not Modified" and and "412 Precondition Failed" responses.

To work around this, you need to manually set the entity using an
undocumented method:

  $c->res->headers->last_modified( $obj->mtime );

  if ($c->modified) {

    # Do more processing to generate the page

  } else {

    $self->_set_entity($c, { error => "Not Modified" });

    return 1;

  }

=head1 SEE ALSO

=over 4

=item * L<Catalyst>

=item * L<Catalyst::Plugin::Cache::HTTP>

=item * L<HTTP 1.1|https://www.ietf.org/rfc/rfc2616.txt>

=back

=head1 AUTHOR

Interactive Information, Ltd C<< <cpan at interactive.co.uk> >>

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Catalyst::Plugin::Cache::HTTP::Preempt

You can also find information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Catalyst-Plugin-Cache-HTTP-Preempt>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Catalyst-Plugin-Cache-HTTP-Preempt>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Catalyst-Plugin-Cache-HTTP-Preempt>

=item * Search CPAN

L<http://search.cpan.org/dist/Catalyst-Plugin-Cache-HTTP-Preempt/>

=back


=head1 LICENSE AND COPYRIGHT

Copyright (c) 2012-2013 Interactive Information, Ltd

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1; # End of Catalyst::Plugin::Cache::HTTP::Preempt
