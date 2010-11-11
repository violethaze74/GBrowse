package Bio::Graphics::Browser2::Render::Synteny::HTML;
use strict;
use warnings;

our $VERSION   = '$Id: gbrowse_details,v 1.7 2009-08-27 19:13:18 idavies Exp $';
our $HAS_DBFILE;
our $HAS_STORABLE;

use CGI qw/:standard Map Area delete_all/;
use CGI::Carp 'fatalsToBrowser';
use CGI::Toggle;
use List::Util qw/min max sum/;
use Digest::MD5 'md5_hex';

use Bio::Graphics;
use Bio::Graphics::Browser2;
use Bio::Graphics::Browser2::Render::HTML;

use base 'Bio::Graphics::Browser2::Render::HTML';

# Legacy libraries from 1.7 branch
# will slowly replace these
use Legacy::Graphics::Browser::Util;
use Legacy::Graphics::Browser::Synteny;
use Legacy::Graphics::Browser::PageSettings;
use Bio::DB::SyntenyIO;
use Bio::DB::SyntenyBlock;

use constant TRACE              => 0;
use constant OVERVIEW_RATIO     => 0.9;
use constant OVERVIEW_BGCOLOR   => 'gainsboro';
use constant IMAGE_WIDTH        => 800;
use constant INTERIMAGE_PAD     => 5;
use constant VERTICAL_PAD       => 40;
use constant ALIGN_HEIGHT       => 6;  
use constant MAX_SPAN           => 0.3;     # largest gap allowed for merging inset panels
use constant TOO_SMALL          => 0.02;    # minimum span for displayed alignments
use constant MAX_GAP            => 50_001;  # maximum gap for chaining
use constant MAX_SEGMENT        => 2_000_001; 
use constant EXTENSION          => 'syn';   # extension for species conf files
use constant DEBUG              => 0;
use constant HELP               => 'http://gmod.org/wiki/GBrowse_syn_Help';

# Display options -- using a hash here so that
# $page_settings can be updated without using hard-coded
# keys (not counting this constant!).
use constant SETTINGS => 
    ( 
      aggregate  => 0 , # chain alignments
      pgrid      => 1,  # gridlines
      shading    => 1,  # shaded polygons
      tiny       => 0,  # ignore small alignments
      pflip      => 1,  # flip (-) strand panels
      edge       => 1,  # outline polygons
      imagewidth => 800,  # width of the image
      display    => 'expanded',  # ref + 2 or all in one
      ref        => undef,
      start      => undef,
      stop       => undef,
      end        => undef,
      name       => undef,
      search_src => undef,
      species    => undef
      );

our $SCONF;

sub run_asynchronous_event { 0 }

sub print_syn_help {
    my $self = shift;
    print header,  start_html('No data source');
    print warning("No data source configured for GBrowse_syn\n"); 
    print p('Please consult '.a({-href=>'http://gmod.org/GBrowse_syn'},'the documentation'));

    print <<END;
<iframe style="frameborder:0;width:800px;height:2000px" src="/gbrowse2/gbrowse_syn_help.html">
</iframe>
END
    print end_html;
}

sub run {

    my $self = shift;

    # print help and exit if there are no synteny sources defined
    my $conf_dir  = $self->globals->conf_dir;
    unless( grep { $self->globals->setting( $_ => 'type' ) eq 'synteny' }
            $self->globals->data_sources
           ) {
        return $self->print_syn_help;
    }

    # redirect to the appropriate URL for the default datasource if we
    # don't have a specified one
    $self->set_source() && return;

    # search soure (general) configuration
    $CONF       = Legacy::Graphics::Browser::Synteny->new();
    $CONF->read_configuration($conf_dir,'synconf');

    # species-specific configuration
    my $extension = $CONF->setting('config_extension') || EXTENSION;
    $SCONF      = open_config($conf_dir,$extension);

    my ($page_settings,$session) = $self->page_settings();
    my $source = $page_settings->{source};
    $CONF->page_settings($page_settings);
    $CONF->search_src($page_settings->{search_src});
    $CONF->source($page_settings->{source});

    $self->syn_io(  Bio::DB::SyntenyIO->new($CONF->setting('join')) );

    my $segment = $self->landmark2segment($page_settings);

    if ($segment) {
        my $name = format_segment($segment);

        if (ref $segment ne 'Bio::DB::GFF::RelSegment') {
            redirect(url()."?name=$name");
        }

        $CONF->current_segment($segment);
        param(name => $name);
        $page_settings->{name} = $name;
    }

    my @reset = (0,0);
    if (param('reset')) {
        @reset = (1, 'All settings have been reset to their default values');
    }
    $CONF->print_page_top($CONF->setting('description'),@reset,$session);

    # warning if trying to search with no species
    if (!$segment && param('name') && !$CONF->page_settings("search_src")) {
        print warning("Error: select a species to search");
    }

    # Which aligned species have been asked for
    my @requested_species  = _unique(@{$page_settings->{species}});
    if (!@requested_species) {
        my $search_src = $page_settings->{search_src} || '';
        unless ($search_src && $search_src ne 'nosrc' && $self->db_map->{$search_src}->{db}) {
            $self->invalid_src = $search_src;
        }
        @requested_species  = grep {$_ ne $search_src} grep {$self->db_map->{$_}->{db}} keys %{$self->db_map};
    }

    if ($segment) {
        $self->hits([
            map { $self->syn_io->get_synteny_by_range(
                -src   => $page_settings->{search_src},
                -ref   => $segment->abs_ref,
                -start => $segment->abs_start,
                -end   => $segment->abs_end,
                -tgt   => $_)
             } @requested_species
        ]);
    }

    my $header = $CONF->setting('header');
    $header = &$header if ref $header;
    print $header || h1($CONF->setting('description'));

    if (my $src = $self->invalid_src) {
        print warning("Species '$src' is not configured for this database");
    }

    $self->search_form($segment);

    print $self->overview_panel($CONF->whole_segment($segment),$segment) if $segment;

    if ($segment) {
        # make sure no hits go off-screen
        $self->remap_coordinates($_) for @{ $self->hits };

        segment_info($page_settings,$segment);

        my %species = map {$_->src2 => 1} @{ $self->hits };
        my @species = sort keys %species;

        # either display ref species + 2 repeating or 'all in one'
        if ($page_settings->{display} eq 'expanded') {
            while (my @pair = splice @species, 0, 2) {
                $self->draw_image($page_settings, $self->hits, @pair);
            }
        } else {
            $self->draw_image( $page_settings, $self->hits, @species );
        } 
    } 

    $self->options_table;
    print end_form();
    print $CONF->footer || end_html();

    # remember former source for the checkbox
    $page_settings->{old_src} = $CONF->search_src;

}

sub species_chooser {
  my $self = shift;

  # pointless if < 3 species
  return '' if keys %{$self->db_map} < 3;
  my $src = $CONF->search_src();
  my @species = grep {$_ ne $src} grep {$self->db_map->{$_}->{db}} keys %{$self->db_map};
  my $default = $CONF->page_settings->{species} || \@species;
  push @$default, $CONF->page_settings('old_src');

  if (!param('species')) {
    $default = [keys %{$self->db_map}];
  }
 
  b(wiki_help('Aligned_Species',,$CONF->tr('Aligned Species'))) . ':' . br .
  checkbox_group(
		 -id        => 'speciesChooser',
		 -name      => 'species',
		 -values    => \@species,
		 -labels    => { map {$_ => $self->db_map->{$_}->{desc} } @species },
		 -default   => $default,
		 -multiple  => 1,
		 -size      => 8,
		 -override  => 1,
	     );
}

sub expand_notice {
  my $self = shift;

  # pointless if < 4 species
  return '' if keys %{$self->db_map} < 4;
  my $state = param('display') || $CONF->page_settings->{display};
  my $ref = $CONF->search_src; 
  my $title = b(wiki_help("Display_Mode",$CONF->tr("Display Mode")), ':');

  my $url = url . "/" . $CONF->source;
  if ($state eq 'expanded') {
    return br, $title, br,  "Three species/panel ",
	a( {-href => $url.'?display=compact'}, 'Click to show all species in one panel');
  } 
  else {
    return br, $title, br, 'All species in one panel ',
    a( {-href => $url.'?display=expanded'}, 'Click to show reference plus two species/panel');
  }
}

sub landmark_search {
  my $segment = shift;
  my $default = format_segment($segment) if $segment;
  return $CONF->setting('no search')
      ? '' : b(wiki_help('Landmark',$CONF->tr('Landmark'))).':'.br.
      textfield(-name=>'name', -size=>25, -value=>$default);
}

sub species_search {
  my $self = shift;
  my $default = $CONF->page_settings("search_src");
  my %labels = map {$_=>$self->db_map->{$_}{desc}} keys %{$self->db_map};
  my $values  = [sort {$self->db_map->{$a}{desc} cmp $self->db_map->{$b}{desc}} grep {$self->db_map->{$_}{desc}} keys %labels];
  unshift @$values, '';

  my $onchange = "document.mainform.submit()";
  return b(wiki_help('Reference_Species',$CONF->tr('Genome to Search'))) . ':' . br .
      popup_menu(
		 -onchange => $onchange,
		 -name     =>'search_src',
		 -values   => $values,
		 -labels   => \%labels,
		 -default  => $default,
		 -override => 1
		 );
}

sub search_form {
  my $self = shift;
  my $segment = shift;
  print start_form(-name=>'mainform',-method => 'post');
  $self->navigation_table($segment);
}

sub db_map {
    my $self = shift;

    $self->{db_map} ||= do {
        my %map;
        my @map = shellwords($CONF->setting('source_map'));
        while (my($symbol,$db,$desc) = splice(@map,0,3)) {
            $map{$symbol}{db}   = $db;
            $map{$symbol}{desc} = $desc;
        }
        \%map;
    };
}

sub _type_from_box {
  my $box = shift;
  my @type = split ':', $box->[0];
  my ($feature,$fname) = @type[0,-1];
  return ($feature,$fname);
}


sub draw_image {
  my ($self,$page_settings,$hits,@species) = @_;
  my ($toggle_section,@hits);
  for my $species (@species) {
    push @hits, grep {$_->src2 eq $species} @$hits;
  }
  
  my $src     = $CONF->page_settings("search_src");
  my $segment = $CONF->current_segment or return;
  my $max_segment = $CONF->setting('max_segment') || MAX_SEGMENT;

  if ( $segment->length > $max_segment) {
    my $units = $CONF->unit_label($max_segment);
    print h2("Sorry: the size of region $segment exceeds the maximum ($units)");
    exit;
  }

  my $max_gap = $segment->length * ($CONF->setting('max_span') || MAX_SPAN);

  # dynamically create synteny blocks
  @hits = aggregate(\@hits) if $CONF->page_settings("aggregate");
  
  # save the hits by name so we can access them from the name alone
  for (@hits) {
    $CONF->name2hit( $_->name => $_ );
  }
 

  # relate hits into "span" sorted by target contig/chromosomes
  # %span = ( target_database,target_contig => { target, contig, start, end } } )
  my (%span,$hit2span,%instance);
  for my $h (sort {$a->tstart <=> $b->tstart} @hits) {
    my $src    = $h->src2;
    my $contig = $h->target;
    $instance{$src,$contig} ||= 0;
    my $key = join $;,$src,$contig,$instance{$src,$contig};

    # start a new span if the gap is too large 
    if ($span{$key} && ($h->tstart >= $span{$key}{end}+$max_gap)) {
      $key = join $;,$src,$contig,++$instance{$src,$contig};
    }

    # Tally the plus and minus strand total.  We will flip the panel
    # if more aligned sequence is on the minus strand than the plus strand.
    # only count actual alignmnts (not aggregates).
    my $panel_flip = $CONF->panel_flip($key);
    if ($h->parts) {
      for my $p (@{$h->parts}) {
	$panel_flip->{$key}{yes} += ($p->tend - $p->tstart) if $p->tstrand eq '-';
	$panel_flip->{$key}{no}  += ($p->tend - $p->tstart) if $p->tstrand eq '+';
      }
    }
    else {
      $panel_flip->{$key}{yes} += ($h->tend - $h->tstart) if $h->tstrand eq '-';
      $panel_flip->{$key}{no}  += ($h->tend - $h->tstart) if $h->tstrand eq '+';
    }

    $span{$key}{start} = $h->tstart
	if !defined $span{$key}{start} or $span{$key}{start} > $h->tstart;

    $span{$key}{end}   = $h->tend
	if !defined $span{$key}{end}   or $span{$key}{end}   < $h->tend;

    $contig =~ s/Superc/C/;
    $span{$key}{src}    ||= $src;
    $span{$key}{contig} ||= $contig;
    $span{$key}{tstart} ||= $h->start;
    $span{$key}{tend}   ||= $h->end;
    ($span{$key}{tstart}) = sort {$a<=>$b} ($h->start,$span{$key}{tstart});
    ($span{$key}{tend})   = sort {$b<=>$a} ($h->end,$span{$key}{tend});
    $hit2span->{$h} = $key;
    $hit2span->{$h->name} = $key;
  }

  # get rid of tiny spans
  my $src_fraction = ($CONF->setting('min_alignment_size') || TOO_SMALL || 0) * $segment->length;
  my @unused_hits;
  unless ($CONF->page_settings("tiny")) {
    for my $key (keys %span) {
      my $too_short = ($span{$key}{end} - $span{$key}{start}) < $src_fraction
	  && ($span{$key}{tend} - $span{$key}{tstart}) < $src_fraction;
      if ($too_short) {
	delete $span{$key};
	push @unused_hits, grep { $hit2span->{$_} eq $key } @hits;
	@hits = grep { $hit2span->{$_} ne $key } @hits;
      }
    }
  }

  # sort hits into upper and lower hits, based on this pattern:
  #
  #   1    3    5    7      upper spans
  #
  #   - - - - - - - - -     upper hits
  #
  #   - - - - - - - - -     lower hits
  #
  #   0    2    4    6      lower spans
  #

  my (%hit_positions);
  my $pidx = 0;
  my %species = map {$_->src2 => 1} @hits;
  my %position = map {$_ => ++$pidx} sort keys %species;
  for my $h (sort {($b->end-$b->start)<=>($a->end-$a->start)} @hits) {
    my $src = $h->src2;
    my $span_key = $hit2span->{$h};
    $span{$span_key}{position} = $position{$src};
    $hit_positions{$h} ||= $span{$span_key}{position};
  }
  
  # Create the middle (reference) panel
  my ($upper_ff,$lower_ff,%is_upper);
  
  # restrict segment to aligned sequence
  my $only_aligned = 0;
  if ($only_aligned && @hits) {
    my @coords = map {$_->start, $_->end} @hits;
    my $new_name = $segment->ref .':'.(min @coords).'..'.(max @coords);
    $segment = $self->landmark2segment($page_settings,$new_name,$CONF->page_settings('search_src'));
  }

  for my $h (@hits) {
    my $src = $h->src2;
    # keep track of the hits for mapping purposes
    $is_upper{$src} ||= $hit_positions{$h} % 2;
    my $ff       = $is_upper{$src} ? \$upper_ff : \$lower_ff;
    $$ff ||= Bio::Graphics::FeatureFile->new;
    $self->add_hit_to_ff($segment,$$ff,$h,$hit2span);
  }

  my $orphan_hit = 0;
  for my $h (@unused_hits) {
    warn "I am an orphan! ".$h->start."..".$h->end."\n" if DEBUG;
    my $is_upper = ++$orphan_hit % 2;
    my $ff       = $is_upper ? \$upper_ff : \$lower_ff;
    $$ff ||= Bio::Graphics::FeatureFile->new;
    $self->add_hit_to_ff($segment,$$ff,$h,$hit2span);
  }

  # base image width
  my $width = $CONF->page_settings('imagewidth') || $CONF->setting("imagewidth") || IMAGE_WIDTH;

  # but also allow for padding
  my $ip = $SCONF->setting('image_padding') || 0;
  my $pl = $SCONF->setting('pad_left')  || 0;
  my $pr = $SCONF->setting('pad_right') || 0;
  my $padding = ($pl || $ip) + ($pr || $ip);

  my ($ref_img,$ref_boxes) = $self->segment2image(
      $segment,
      $src,
      {
          width           => $width - $padding,
          features_top    => $upper_ff,
          features_bottom => $lower_ff,
          background      => 'white',
      }
     ) or die("no image");

  $width = $ref_img->width;

  my $ref_title = $self->db_map->{$src}{desc} . ' ' . format_segment($segment);

  # pad all of the span coordinates for a bit of regional context 
  for my $key (keys %span) {
    my $width = $span{$key}{end} - $span{$key}{start};
    $span{$key}{start} -= int $width/20;
    $span{$key}{end  } += int $width/20;
  }

  # we now create panels and corresponding hit feature files for each of the small
  # panels
  my $refwidth     = $width;
  my $panel_count  = keys %span;
  my $panels_above = my @panels_above = grep { $span{$_}{position} % 2 } keys %span;
  my $panels_below = my @panels_below = grep {!($span{$_}{position} % 2) } keys %span;
  my $bases_above  = sum( map {$span{$_}{end} - $span{$_}{start}} @panels_above );
  my $bases_below  = sum( map {$span{$_}{end} - $span{$_}{start}} @panels_below );
  my ($pad_top,$pad_bottom) = (0,0);
  my ($img,$boxes);
  my $im_pad = $CONF->setting('interimage_pad') || INTERIMAGE_PAD;

  for my $key (keys %span) {
    my $panel_position   = $span{$key}{position};
    my $is_above         = $panel_position % 2;
    my $total_bases      = $is_above ? $bases_above : $bases_below;
    my $panels           = $is_above ? $panels_above : $panels_below;
    my $total_width      = $refwidth - $panels*3*$im_pad + $im_pad;
    my $src              = $span{$key}{src};
    my $contig           = $span{$key}{contig};
    my $end              = $span{$key}{end};
    my $start            = $span{$key}{start};
    my $bases            = $end - $start;
    my $name             = "$contig:$start..$end";
    my $segment          = $self->landmark2segment($page_settings,$name,$src);
    my @relevant_hits    = grep {$hit2span->{$_} eq $key} @hits;

    my $rsegment = $self->landmark2segment($page_settings,"$contig:$start..$end",$src);

    # width of inset panels scaled by size of target sequence
    $bases or next;
    my $scale = $bases/$total_bases;
    my $width = $total_width*$scale;

    my $ff    = Bio::Graphics::FeatureFile->new;
    $self->add_hit_to_ff($rsegment,$ff,$_,$hit2span,'invert') foreach @relevant_hits;

    my $segment_args = {width => $width};
    if ($is_above) {
      $segment_args->{features_bottom} = $ff;
      $segment_args->{noscale} = 1;
    }
    else {
      $segment_args->{features_top} = $ff;
    }

    $segment_args->{flip}++ if panel_is_flipped($key,1);

    ($img,$boxes)     = $self->segment2image($segment, $src, $segment_args);

    $img or next;
    $span{$key}{image} = $img;
    $span{$key}{boxes} = $boxes;
    $span{$key}{title} = $self->db_map->{$src}{desc};
    $span{$key}{title} .= ' (reverse)' if panel_is_flipped($key);

    $pad_top    = $img->height if $is_above  && $pad_top < $img->height;
    $pad_bottom = $img->height if !$is_above && $pad_bottom < $img->height;
  }

  # total height is height of reference + pad_top + pad_bottom + VERTICAL_PAD pixels of spacing
  my $total_height = $ref_img->height + $pad_top + $pad_bottom;
  my $vertical_pad = $CONF->setting('vertical_pad') || VERTICAL_PAD;
  $total_height   += $vertical_pad   if $panels_above;
  $total_height   += $vertical_pad   if $panels_below;
  $total_height   += $im_pad;

  # create a master image for all panels
  my $gd = GD::Image->new($ref_img->width+2*$im_pad,$total_height+1,1) or return;
  $gd->saveAlpha(0);
  $gd->alphaBlending(1);
  my $white       = $gd->colorAllocate(255,255,255);
  my $black       = $gd->colorAllocate(0,0,0);
  my $cyan        = $gd->colorAllocate(0,255,255);
  $gd->filledRectangle(0,0,$gd->width,$gd->height,$white);
  my $translucent = $gd->colorAllocateAlpha(0,0,255,90);

  for my $key (keys %span) {
    my $color            = $CONF->setting($self->db_map->{$span{$key}{src}}{db}=>'color');
    # report missing config for the species if no color is found
    my $db = $self->db_map->{$span{$key}{src}}{db};
    $color || die <<END;
    No color configured for $db.
    Check the \[$db\] stanza in your main configuration file;
END

    my @colrgb = Bio::Graphics::Panel->color_name_to_rgb($color);
    $span{$key}{tcolor}  = $gd->colorAllocateAlpha(@colrgb,110);
    $span{$key}{bgcolor} = $gd->colorAllocateAlpha(@colrgb,115);
    $span{$key}{border}  = $gd->colorResolve(@colrgb);
  }

  my $ref_top    = $panels_above ? $pad_top + $vertical_pad  : $im_pad;
  my $ref_bottom = $ref_top + $ref_img->height;

  # paste the individual panels into the picture
  my @map_items;
  my %x = ( above => $im_pad, below => $im_pad);

  # order the panels by hit order 
  my (@sorted_spans,%seen_span);
  for my $h (sort {$a->start <=> $b->start} @hits) {
    my $span = $hit2span->{$h};
    push @sorted_spans, $span if ++$seen_span{$span} == 1;
  }

  my $max_height_above = max( map {eval{$span{$_}{image}->height}} grep {$span{$_}{position} % 2} @sorted_spans);
  my $max_height_below = max( map {eval{$span{$_}{image}->height}} grep {! ($span{$_}{position} % 2)} @sorted_spans);

  for my $key (@sorted_spans) {
    my $is_above = $span{$key}{position} % 2;
    my $img = $span{$key}{image} or next;
    my $xi = $is_above ? 'above' : 'below';
    my $max_height = $is_above ? $max_height_above : $max_height_below;
    
    my $img_y = $is_above ? $ref_top-$vertical_pad-$img->height : $ref_bottom+$vertical_pad ;
    my $msk_y  = $is_above ? $ref_top-$vertical_pad-$max_height : $img_y;
    $span{$key}{offsets} = [$x{$xi},$img_y];
    my @rect = ($x{$xi},$msk_y,$x{$xi}+$img->width,$msk_y+$max_height);
    $gd->copy($img,$x{$xi},$img_y,0,0,$img->width,$img->height);

    $gd->filledRectangle(@rect,$span{$key}{bgcolor});
    $gd->rectangle(@rect,$span{$key}{border});
    $gd->string(GD::gdSmallFont,$x{$xi}+5,$msk_y,$span{$key}{title},$black)
	if $img->width > 75;
    $x{$xi} += $img->width + $im_pad;
    my $name = "$span{$key}{contig}:$span{$key}{start}..$span{$key}{end}";
    push @map_items,Area({shape=>'rect',
			  coords=>join(',',@rect),
			  href=>"?search_src=$span{$key}{src};name=$name",
			  title=>$span{$key}{title}});
  }

  # middle row (reference)
  my @rect = ($im_pad,$ref_top,$im_pad+$ref_img->width,$ref_top+$ref_img->height);
  $gd->copy($ref_img,$im_pad,$ref_top,0,0,$ref_img->width,$ref_img->height);
  my $color   = $CONF->setting($self->db_map->{$src}{db}=>'color');
  $color ||= 'blue';
  my $bgcolor = $gd->colorAllocateAlpha(Bio::Graphics::Panel->color_name_to_rgb($color),110);
  my $border  = $gd->colorResolve(Bio::Graphics::Panel->color_name_to_rgb($color));
  $gd->filledRectangle(@rect,$bgcolor);
  $gd->rectangle(@rect,$border);
  my $title = $self->db_map->{$src}{desc} . ' (reference)';
  $gd->string(GD::gdSmallFont,$rect[0]+5,$rect[1],$title,$black);
  push @map_items,Area({shape=>'rect',
			coords=>join(',',@rect),
			title=>$ref_title});

  # sort out the coordinates of all the hits so that we can join them
  # first the hits in the reference panel
  my (%ref_boxes,%panel_boxes);
  for my $box (@$ref_boxes) {
    ref $box or next;
    my ($feature,$fname) = _type_from_box($box);
    my @rect = ($im_pad+$box->[1],$ref_top+$box->[2],$im_pad+$box->[3],$ref_top+$box->[4]);
    if ($feature =~ /^match(_part)?$/) {
      $ref_boxes{$fname} = \@rect;		
    }
    else {
      my %atts = %{$box->[5]};
      my $url = url();
      $url =~ s/gbrowse_syn.*$//;
      $atts{href} =~ s/\.\.\/\.\.\//$url/ if $atts{href};
      push @map_items,Area({shape=>'rect',coords=>join(',',@rect),%atts});
    }	
    $gd->rectangle(@rect,$black) if DEBUG;
  }

  # now for the hits in each individual panel
  my %tcolors;
  for my $key (keys %span) {
    defined $span{$key}{offsets} or next;
    my ($left,$top) = @{$span{$key}{offsets}};
    my $boxes  = $span{$key}{boxes};
    for my $box (@$boxes) {
      ref $box or next;
      my ($feature,$fname) = _type_from_box($box);
      #next unless $feature =~ /^match(_part)?$/;
      my @rect = ($left+$box->[1],$top+$box->[2],$left+$box->[3],$top+$box->[4]);
      if ($feature =~ /^match(_part)?$/) {
        $panel_boxes{$fname} = \@rect;
      }
      else {
        push @map_items, Area( {
	  shape  => 'rect',
	  coords => join(',',@rect),
	  %{$box->[5]}});
      }
      $tcolors{$fname} = $span{$key}{tcolor};

      $gd->rectangle(@rect,$black) if DEBUG;
    }
  }
  
  my %grid_line;
  my %gc;
  $gc{1} = $CONF->page_settings("pgrid") ? $gd->colorResolveAlpha(10,10,10,100) : $gd->colorResolveAlpha(10,10,10,70);
  $gc{3} = $gd->colorResolveAlpha(10,10,255,100);
  my $thickness = 3;

  my $grid_upper;
  for my $feature (keys %ref_boxes) { 
    next unless defined $ref_boxes{$feature} && defined $panel_boxes{$feature};
    my $hit = $CONF->name2hit($feature);
    next unless defined $hit;
    my $span = $hit2span->{$feature};
    my $flip =  !panel_is_flipped($span) && $CONF->flip($feature)
             ||  panel_is_flipped($span) && !$CONF->flip($feature);

    my ($rx1,$ry1,$rx2,$ry2) = @{$ref_boxes{$feature}};
    my ($px1,$py1,$px2,$py2) = @{$panel_boxes{$feature}};
    my $upper = $py2 < $ry1;    

    if ($CONF->page_settings("shading")) {
      my $poly = GD::Polygon->new();
      $upper = $py2 < $ry1;
      ($rx1,$rx2) = ($rx2,$rx1) if $flip;

      if ($upper) {
	$grid_upper ||= $ry2;
	$poly->addPt($px1,$py2);
	$poly->addPt($px2,$py2);
	$poly->addPt($rx2,$ry1);
	$poly->addPt($rx1,$ry1);
      } 
      else {
	$poly->addPt($px1,$py1);
	$poly->addPt($px2,$py1);
	$poly->addPt($rx2,$ry2);
	$poly->addPt($rx1,$ry2);
      }
      
      $gd->filledPolygon($poly,$tcolors{$feature});
    }
  }

  my %within_a_pixel;
  # reloop to avoid mysterious alpha-channel interaction
  # between shading and grid-lines
  for my $feature (keys %ref_boxes) {
    next unless defined $ref_boxes{$feature} && defined $panel_boxes{$feature};
    next if $feature =~ /aggregate/;
    my $exact = $CONF->setting('grid coordinates');    
    $exact = $exact && $exact eq 'exact';

    next unless my $hit = $CONF->name2hit($feature);

    my $span = $hit2span->{$feature};
    my $flip =  !panel_is_flipped($span) && $CONF->flip($feature)
             ||  panel_is_flipped($span) && !$CONF->flip($feature);

    my ($rx1,$ry1,$rx2,$ry2) = @{$ref_boxes{$feature}};
    my ($px1,$py1,$px2,$py2) = @{$panel_boxes{$feature}};
    my $upper = $py2 < $ry1;

    my @grid_coords = $CONF->page_settings("pgrid") 
	? $self->grid_coords(
            $hit,
            $ref_boxes{$feature},
            $panel_boxes{$feature},
            panel_is_flipped($span),
            $segment
          )
        : ();

    # add edges
    if ($CONF->page_settings("edge")) {
      unshift @grid_coords, $flip ? [$rx1,$px2] :  [$rx1,$px1];
      push @grid_coords, $flip ? [$rx2,$px1] :  [$rx2,$px2];
    }

    my $tidx = 0;
    for my $pair (@grid_coords) {
      my ($x1,$x2) = @$pair;
      $grid_line{$x1}{thickness} = 1 if $exact;
      unless ($grid_line{$x1}{thickness}) {
	$thickness = ++$tidx == 5 ? 3 : 1;
	$tidx = 0 if $tidx == 5;
      }
      else {
	$thickness = $grid_line{$x1}{thickness};
      }
      $gd->setThickness($thickness);
      if ($upper) {
	$gd->line($x1,$ry1,$x2,$py2,$gc{$thickness});
	$gd->line($x2,$py2,$x2,0,$gc{$thickness});
	$grid_line{$x1}{top} ||= $ry2;
      }
      else {
        my $pad = $im_pad;
	$gd->line($x1,$ry2,$x2,$py1,$gc{$thickness});
	$gd->line($x2,$py1,$x2,$gd->height-$pad-1,$gc{$thickness});
	$grid_line{$x1}{bottom} ||= $ry1;
      }
      $grid_line{$x1}{thickness} ||= $thickness;
    }
  }
  
  
  for my $g (keys %grid_line) {
    # skip the line if there is one already drawn
    # a pixel to the left or right;
    next if $within_a_pixel{$g-1} || $within_a_pixel{$g+1} || $within_a_pixel{$g};
    $within_a_pixel{$g} = 1;
    my $thickness = $grid_line{$g}{thickness};
    $gd->setThickness($thickness);
    $grid_line{$g}{top}    ||= $grid_upper;#$ref_top;
    $grid_line{$g}{bottom} ||= $ref_bottom;
    $gd->line($g,$grid_line{$g}{top},$g,$grid_line{$g}{bottom},$gc{$thickness});
  }
  
  my $url = $SCONF->generate_image($gd);
  
  my $label = $CONF->page_settings->{display} eq 'compact' ? # all
              'Details'                                    : # or a sub-set
               join(', ',@species);
  my $map_name = md5_hex($label);
  print toggle( $label,
		table( {-width=>'100%'},
		       Tr( td( {-align=>'center', -class => 'databody'},
			       img({-src=>$url,-border=>0,-usemap=>'#'.$map_name} )))
		       ),
		);
  
  my $map = Map({-name=>$map_name},reverse @map_items);
  $map =~ s/\</\n\</g;
  print $map;
}

sub segment2image {
  my ($self,$segment,$src,$options) = @_;
  $segment or return;

  my $width       = $options->{width};
  my $hits_top    = $options->{features_top};
  my $hits_bottom = $options->{features_bottom};
  my $background  = $options->{background} || 'white';
  my $flip        = $options->{flip};

  my $dsn = $self->db_map->{$src}{db} or return;
  $SCONF->source($dsn);
  # make sure balloon tooltips are turned on 
  $SCONF->setting('GENERAL','balloon tips',1);

  my @tracks    = shellwords($CONF->setting($dsn => 'tracks'));
  my $ff_scale  = Bio::Graphics::FeatureFile->new;
  $ff_scale->add_type( SCALE => { fgcolor => 'black', 
				  glyph   => 'arrow',
				  tick    => 2,
				  double  => 0,
				  description => 0} );


  $ff_scale->add_feature(segment2feature($segment,$ff_scale));
  
  my @labels;
  if ($hits_top && $hits_bottom) {
    @labels = ('ff_top','ff_scale',@tracks,'ff_bottom');
  }
  elsif ($hits_top) {
    @labels = ('ff_top','zz_scale',@tracks);
  }
  elsif ($hits_bottom) {
    @labels = (@tracks,'ff_scale','ff_bottom');
  }
  else {
    @labels = ('ff_scale',@tracks);
  }

  my %ff_hash;
  $ff_hash{ff_top}    = $hits_top    if $hits_top;
  $ff_hash{ff_bottom} = $hits_bottom if $hits_bottom;

  # coerce correct track order in bottom panel
  my $scale_label = $hits_bottom && !$hits_bottom ? 'zz_scale' : 'ff_scale';
  $ff_hash{$scale_label}  = $ff_scale;

  $SCONF->width($width);
  
  my $im_pad = $CONF->setting('interimage_pad') || INTERIMAGE_PAD;

  # padding must be temporarily overridden for inset panels
  my ($pl,$pr);
  unless ($src eq $CONF->search_src()) {
    $pl = $SCONF->setting('pad_left');
    $pr = $SCONF->setting('pad_right');
    $SCONF->setting('general','pad_left'  => $im_pad);
    $SCONF->setting('general','pad_right' => $im_pad);
  }

  $SCONF->setting('general','detail bgcolor'=> $background);

  my $title = $self->db_map->{$src}{desc};

  # cache no panels if some params change
  my $no_cache = [md5_hex(url(-query_string=>1))];

  $self->landmark2segment if _isref($segment);
  
  my ($img,$boxes) = $SCONF->render_panels( 
					    { 
					      drag_n_drop => 0,
					      image_and_map => 1,
					      keystyle  => 'none',
					      segment   => $segment,
					      labels    => \@labels,
					      title     => $title,
					      -grid     => 0,
					      do_map    => 1,
					      noscale   => 1,
					      feature_files=>\%ff_hash,
					      -flip     => $flip,
					      cache_extra => $no_cache, 
					    }
					    );
  

  # restore original padding
  unless ($src eq $CONF->search_src()) {
    $SCONF->setting('general','pad_left'  => $pl);
    $SCONF->setting('general','pad_right' => $pr);
  }

  return ($img,$boxes,$segment);
}

sub _isref {
  my $segment = shift;
  return $segment->ref eq $CONF->page_settings('ref') &&
      $segment->start == $CONF->page_settings('start') &&
      $segment->stop  == $CONF->page_settings('stop'); 
}

sub format_segment {
  my $seg = shift;
  return $seg->ref.':'.$seg->start.'..'.$seg->end;
}

sub landmark2segment {
  my $self = shift;
  my $settings = shift || $CONF->page_settings;
  my ($name,$source) = @_;
  if ($name && $source) {
  }
  elsif ($CONF->page_settings("name")) {
    $name   = $CONF->page_settings("name");
  }
  elsif ($CONF->page_settings("ref")) {
    $name  = $CONF->page_settings("ref") . ':';
    $name .= $CONF->page_settings("start") . ':';
    $name .= $CONF->page_settings("stop");
  }

  $source ||= $CONF->page_settings("search_src");

  my $segment  = $self->_do_search($name,$source) if $name && $source;

  # Did not find our segment?  Try the other species
  if (!$segment) {
    for my $src (grep {defined $_} @{$settings->{species}}) {
      next if $src eq $source;
      $segment = $self->_do_search($name,$src) if $name;
      if ($segment) {
	$settings->{search_src} = $src;
	$CONF->search_src($src);
	last;
      }
    }
  }

  # remember our search!
  if ($segment && $source && $source eq $settings->{search_src}) {
    $settings->{"ref"}   = $segment->ref;
    $settings->{"start"} = $segment->start;
    $settings->{"stop"}  = $segment->end;
    $settings->{"name"}  = format_segment($segment);
  }
 
  return $segment;
}

sub _do_search {
  my ($self,$landmark,$src) = @_;
  my $dsn = $self->db_map->{$src}{db} or return undef;
  $SCONF->source($dsn);
  my $db = open_database();
  my ($segment) = grep {$_} $SCONF->name2segments($landmark,$db);
  return $segment;
}

sub warning {
  h2({-style=>'color:red'},@_);
}

sub add_hit_to_ff {
  my ($self,$segment,$ff,$hit,$hit2span,$invert) = @_;
  my $flip_hit = $hit->tstrand eq '-';
  $CONF->flip($hit->name => 1) if $flip_hit;
  my @attributes = $flip_hit ? (-attributes => {flip=>1}) : ();

  my $src = $hit->src2;
  my $setcolor = $CONF->setting($self->db_map->{$src}->{db} => 'color');

  $ff->add_type(
		"match:$src" => {
		  bgcolor   => $setcolor,
		  fgcolor   => $setcolor,
		  height    => $CONF->setting('align_height') || ALIGN_HEIGHT,
		  glyph     => 'segments',
		  label     => 0,
		  box_subparts => 1,
		  connector => 'dashed',
		    },
		);

  my $seqid  = $invert ? $hit->target  : $hit->seqid;
  my $strand = $invert ? $hit->tstrand : $hit->strand;
  my $start  = $invert ? $hit->tstart  : $hit->start;
  my $end    = $invert ? $hit->tend    : $hit->end;

  my $feature = Bio::Graphics::Feature->new(
					    -source   => $src,
					    -type     => 'match',
					    -name     => $hit->name,
					    -seq_id   => $seqid,
					    -strand   => $strand eq '-' ? -1 : 1,
					    -configurator => $ff
					    );

  my $parts = $CONF->{parts}->{$hit->name};

  if ($parts) {
    for my $part (@$parts) {
      $CONF->flip($part->name => 1) if $flip_hit;
      $hit2span->{$part->name} = $hit2span->{$hit};
      $CONF->name2hit($part->name => $part);

      my $start = $invert ? $part->tstart : $part->start;
      my $end   = $invert ? $part->tend : $part->end;
      my $subfeat = Bio::Graphics::Feature->new(
						-type     => 'match_part',
						-name     => $part->name,
						-start    => $start,
						-end      => $end,
						-strand   => $strand
						);
      $feature->add_segment($subfeat,'EXPAND');
    }
  }
  else {
    $feature->start($start);
    $feature->end($end);
  }

  $ff->add_feature($feature);
}

sub adjust_container {
  my $h = shift;

  if ($h->parts) {
    my @coords = map {$_->tstart,$_->tend} @{$h->parts};
    my ($max,$min)  = (max(@coords),min(@coords));
    $h->tstart($min) if $h->tstart != $min;
    $h->tend($max)   if $h->tend   != $max;
    @coords = map {$_->start,$_->end} @{$h->parts};
    ($max,$min)  = (max(@coords),min(@coords));
    $h->start($min) if $h->start != $min;
    $h->end($max)   if $h->end   != $max;
   }

  return $h;
}

sub navigation_table {
  my $self = shift;
  my $segment = shift;
  my @species = @_;

  my ($table,$whole_segment);

  my $slidertable = '';
  if ($segment) {
    my $whole_segment = $CONF->whole_segment();
    my ($label)  = $CONF->tr('Scroll');
    $slidertable = $CONF->slidertable;
  }
  elsif (my $name = $CONF->page_settings('name')) {
    $slidertable = "$name not found in ".($CONF->search_src||'NO SPECIES SELECTED');
    my $style = "font-size:90%;color:red";
    $slidertable = p(b(span({-style=>$style},$slidertable)));
  }

  $CONF->section_setting(Instructions => 'open');
  $CONF->section_setting(Search => 'open');

 		   
  $table .= toggle( $CONF->tr('Instructions'),
			   div({-class=>'searchtitle'},
			       br.'Select a Region to Browse and a Reference species:',
			       p($CONF->show_examples())));
  
  my $html_frag = $self->invalid_src ? '' : html_frag($segment,$CONF->page_settings);
  $table .= toggle( $CONF->tr('Search'),
                    table({-border=>0, -width => '100%', -cellspacing=>0},
                          TR({-class=>'searchtitle'},
                             td({-align=>'left', -colspan=>3},
                                $html_frag
                                )
                             ),
			  TR({-class=>'searchtitle'},
			     td({-align=>'left', -width=>'30%'},
				[
				 landmark_search($segment) . '&nbsp;' .
				 submit(-name=>$CONF->tr('Search')) .
				 reset(-name=>$CONF->tr('Reset'), -onclick=>"window.location='?reset=1'"),
				 $self->species_search,
				 $slidertable
				 ]
				)
			     ),
			  TR({-class=>'searchtitle'},
			     td({-colspan=>3},$self->species_chooser)
                            ),
			  TR({-class=>'searchtitle'},
			     td({-valign=>'bottom'},
				source_menu()
				) .
			     td( {-colspan=>2, -valign=>'bottom'},
				$self->expand_notice
				)
			     ),
			  ) # end table
		    ); # end toggle section

  print $table,br;
}

sub expand_display {
  my $self = shift;
  return '' if keys %{$self->db_map} < 4;
  my $options = [qw/expanded compact/];
  my $labels  = { expanded => 'ref. species plus 2',
		  compact  => 'all species in one panel' };
  my $default = ['expanded'];
  my $name    = 'display';

  b(' ', wiki_help("Display Mode",$CONF->tr('Display Mode')), ': ') .
  popup_menu({-name => $name, -labels => $labels, -values => $options, -default => $default});
}

sub options_table {
  my $self = shift;
  my @onclick = ();
  my $radio_style = {-style=>"background:lightyellow;border:5px solid lightyellow", @onclick};
  my $space = '&nbsp;&nbsp';
  my @grid = (span($radio_style, option_check('Grid lines', 'pgrid'))) unless $self->syn_io->nomap;

  print toggle( $CONF->tr('Display_settings'),
                table({-cellpadding => 5, -width => '100%', -border => 0, -class => 'searchtitle'},
                      TR(
                         td(
                            b(wiki_help('Image Widths',$CONF->tr('Image widths')), ': '),
                            span( $radio_style, radio_group( -name   => 'imagewidth',
                                                             -values => [640,768,800,1024,1280],
                                                             -default=>$CONF->page_settings('imagewidth'),
                                                             @onclick ))
                            ),
                         td(
                             $self->expand_display
                             ),
                         td(
                            submit(-name => 'Update Image')
                            )
                         ),
                      TR(
                         td( {-colspan => 3},
                             b(wiki_help('Image Options',$CONF->tr('Image options')), ': '),
                             div(
                                 span($radio_style, option_check('Chain alignments', 'aggregate')),$space,
                                 span($radio_style, option_check('Flip minus strand panels', 'pflip')),$space,
                                 @grid,
                                 span($radio_style, option_check('Edges', 'edge')), $space,
                                 span($radio_style, option_check('Shading', 'shading')),
                                 )
                             )
                         )
                      )
                );
}


sub option_check {
  my $label = shift;
  my $name  = shift;
  $label = wiki_help($label,$CONF->tr($label));
  my $checked = $CONF->page_settings("$name") ? 'on' : 'off';
  return $label.' '.radio_group(-name => $name, -values => [qw/on off/], -default =>$checked);
}

sub source_menu {
  my $settings = shift;
  my @sources      = $CONF->sources;
  my $show_sources = $CONF->setting('show sources');
  $show_sources    = 1 unless defined $show_sources;   # default to true
  my $sources = $show_sources && @sources > 1;
  my $source = $CONF->get_source;
  return $sources ? b(wiki_help('Data Source',$CONF->tr('Data Source')), ': ') . br.
      popup_menu(-onchange => 'document.mainform.submit()',
		 -name   => 'source',
		 -values => \@sources,
		 -labels => { map {$_ => $CONF->description($_)} $CONF->sources},
		 -default => $source,		 
		 ) : $CONF->description($sources[0]);
}


sub aggregate {
  my $hits = shift;
  $CONF->{parts} = {};

  my @sorted_hits = sort { $a->target cmp $b->target || $a->tstart <=> $b->tstart} @$hits;

  my (%group,$last_hit);

  for my $hit (@sorted_hits) {
    if ($last_hit && belong_together($last_hit,$hit)) {
      push @{$group{$last_hit}}, $hit;
      $group{$hit} = $group{$last_hit};
    }
    else {
      push @{$group{$hit}}, $hit;
    }

    $last_hit = $hit;
  }

  $hits = [];
  my %seen;
  for my $grp (grep {++$seen{$_} == 1} values %group) {
    if (@$grp > 1) {
      my @coords  = sort {$a<=>$b} map {$_->start,$_->end}   @$grp;
      my @tcoords = sort {$a<=>$b} map {$_->tstart,$_->tend} @$grp;
      my $hit = Bio::DB::SyntenyBlock->new($grp->[0]->name."_aggregate");
      $hit->add_part($grp->[0]->src,$grp->[0]->tgt);
      $hit->start(shift @coords);
      $hit->end(pop @coords);
      $hit->tstart(shift @tcoords);
      $hit->tend(pop @tcoords);
      $CONF->{parts}->{$hit->name} = $grp;
      push @$hits, $hit;
    }
    else {
      push @$hits, $grp->[0];
    }
  }

  return @$hits;
}

sub belong_together { 
  my ($feat1,$feat2) = @_;
  my $max_gap = $CONF->setting('max_gap') || MAX_GAP;
  return unless $feat1->target  eq $feat2->target;  # same chromosome
  return unless $feat1->seqid   eq $feat2->seqid;   # same reference sequence
  return unless $feat1->tstrand eq $feat2->tstrand; # same strand                                                                                            
  if ($feat1->tstrand eq '+') {
    return unless $feat1->end < $feat2->end;   # '+' strand monotonically increasing                                                                            
  } else {
    return unless $feat1->end > $feat2->end;   # '-' strand monotonically decreasing                                                                            
  }
  my $dist1 = abs($feat2->end - $feat1->start);
  my $dist2 = abs($feat2->tend - $feat1->tstart);
  return unless $dist2 < $max_gap && $dist1 < $max_gap;
  return $dist2;
}


sub overview_panel {
  my ($self,$whole_segment,$segment) = @_;
  return '' if $SCONF->section_setting('overview') eq 'hide';
  my $image = $self->overview($whole_segment,$segment);
  my $ref = $self->db_map->{$CONF->page_settings("search_src")}->{desc};
  return toggle('Overview',
                table({-border=>0,-width=>'100%'},
		      TR(th("<center>Reference genome: <i>$ref</i></center>")),
                      TR({-class=>'databody'},
                         td({-align=>'center'},$image)
                        )
                     )
		);
}

sub overview {
  my ($self,$region_segment,$segment) = @_;
  return unless $segment;
  my $width = $CONF->page_settings('imagewidth')   || IMAGE_WIDTH;
  $width *= $CONF->setting('overview_ratio') || OVERVIEW_RATIO;
  $CONF->width($width);
  
  # the postgrid will be invoked to hilite the currently selected region
  my $postgrid = hilite_regions_closure([$segment->start,$segment->end,'yellow']);

  # reference genome
  my $ref = $self->db_map->{$CONF->page_settings("search_src")}->{desc};

  my ($overview)   = $CONF->render_panels(
						  {
						    length         => $segment->length,
						    section        => 'overview',
						    segment        => $region_segment,
						    postgrid       => $postgrid,
						    label_scale    => 2,
						    lang           => $SCONF->language,
						    keystyle       => 'left',
						    settings       => $CONF->page_settings(),
						    scale_map_type => 'centering_map',
						    cache_extra    => [$segment->start,$segment->end],
						    do_map         => 1,
						    drag_n_drop    => 0,
						    image_button   => 0,
						    -grid          => 0,
						    -pad_top       => 5,
						    -bgcolor       => $CONF->setting('overview bgcolor') || OVERVIEW_BGCOLOR,
						  }
						  );

  # make sure overview is busy with redirects
  #my $server =$ENV{SERVER_NAME};
  #if ($server) {
  #  $overview =~ s/src="/src="http:\/\/$server\//;
  #}

  return div({-id=>'overview',-class=>'track'},$overview);
}

sub toggle {
  my $title         = shift;
  my @body           = @_;

  my $id      = "\L${title}_panel\E";
  my ($label) = $CONF->tr($title)              or return '';
  my $state   = $CONF->section_setting($title) || 'open';
  return '' if $state eq 'off';
  my $settings = $CONF->page_settings;
  my $visible = exists $settings->{section_visible}{$id} ? $settings->{section_visible}{$id} : $state eq 'open';
  $settings->{section_visible}{$id} = $state eq 'open';

  return toggle_section({on=>$visible},
			$id,
			b($label),
			@body);
}

sub get_options {
  my $tracks_to_show = shift;
  my $settings = $CONF->page_settings;
  my %options    = map {$_=>$settings->{features}{$_}{options}} @$tracks_to_show;
  my %limits     = map {$_=>$settings->{features}{$_}{limit}}   @$tracks_to_show;
  return (\%options,\%limits);
}

sub hilite_regions_closure {
  my @h_regions = @_;

  return sub {
    my $gd     = shift;
    my $panel  = shift;
    my $left   = $panel->pad_left;
    my $top    = $panel->top;
    my $bottom = $panel->bottom;
    for my $r (@h_regions) {
      my ($h_start,$h_end,$h_color) = @$r;
      my ($start,$end) = $panel->location2pixel($h_start,$h_end);
      if ($end-$start <= 1) { $end++; $start-- } # so that we always see something

      # assuming top is 0 so as to ignore top padding
      $gd->filledRectangle($left+$start,0,$left+$end,$bottom,
			   $panel->translate_color($h_color));
    }
  };
}

sub feature2segment {
  my $feature = shift;
  return $feature if ref $feature eq 'Bio::DB::GFF::RelSegment';
  my $refclass = $CONF->setting('reference class') || 'Sequence';
  my $db = open_database();
  my $version = eval {$_->isa('Bio::SeqFeatureI') ? undef : $_->version};
  return $db->segment(-class => $refclass,
		      -name  => $feature->ref,
		      -start => ($feature->start - int($feature->length/20)),
		      -stop  => ($feature->end + int($feature->length/20)),
		      -absolute => 1,
		      defined $version ? (-version => $version) : ());
}

sub segment2feature {
  my $segment = shift;
  my $ff      = shift;
  my $start = $segment->start;
  my $end   = $segment->end;
  my $type  = 'SCALE';
  return Bio::Graphics::Feature->new( -start    => $start,
				      -end      => $end,
				      -type     => $type,
				      -name     => $segment->ref,
				      -seq_id   => $segment->ref,
				      -configurator => $ff
				      );
}


sub expand {
  my $seq = shift;
  $seq =~ s/(\S)(\d+)/($1 x $2)/eg;
  return $seq;
}

sub remap_coordinates {
  my $self    = shift;
  my $hit     = shift;
  my $segment = shift || $CONF->current_segment;
  my $flip    = $hit->tstrand eq '-';

  return unless $hit->start < $segment->start || $hit->end > $segment->end;

  if ($hit->start < $segment->start) {
    my ($new_start,$new_tstart) = $self->syn_io->get_nearest_position_match($hit,$hit->src1,$segment->start,1000);
    unless ($new_start) {
      ($new_start,$new_tstart) = guess_nearest_position_match($hit,$segment->start,$flip);
    }
    if ($new_start) {
      my $hsp = $hit->parts->[0];
      $hsp->start($new_start);
      $flip ? $hsp->tend($new_tstart) : $hsp->tstart($new_tstart);
    }
  }
  if ($hit->end > $segment->end) {
    my ($new_end,$new_tend) = $self->syn_io->get_nearest_position_match($hit,$hit->src1,$segment->end,1000);
    unless ($new_end) {
      ($new_end,$new_tend) = guess_nearest_position_match($hit,$segment->end,$flip);
    }
    if ($new_end) {
      my $hsp = $hit->parts->[-1];
      $hsp->end($new_end);
      $flip ? $hsp->tstart($new_tend) : $hsp->tend($new_tend);
    }
  }
  $hit = adjust_container($hit);
}

# If we can't get a mapped coordinate, interpolate based
# on relative hit lengths
sub guess_nearest_position_match { 
  my $hit   = shift;
  my $coord = shift;
  my $flip  = shift;
  my $hlen = $hit->end - $hit->start;
  my $tlen = $hit->tend - $hit->tstart;
  my $lratio = $tlen/$hlen;
  my $hoffset = $coord - $hit->start;
  my $toffset = $lratio * $hoffset;
  my $WAG = int($flip ? $hit->tend - $toffset : $hit->tstart + $toffset);
  return ($coord,$WAG);
}


# take a vote to flip the panel: the majority strand wins
sub panel_is_flipped { 
  my $key = shift;
  return 0 unless $CONF->page_settings('pflip');
  my $panel_flip = $CONF->panel_flip($key);
  my $yes = $panel_flip->{$key}{yes} || 0;
  my $no  = $panel_flip->{$key}{no}  || 0;
  return $yes > $no;
}

# map the reference and target coordinates to pixel locations
# to draw gridlines
sub locations2pixels {
  my ($self,$loc,$hit,$refbox,$hitbox,$flip,$loc2) = @_;
  #my $reversed = $hit->strand ne $hit->tstrand;

  my ($ref_location,$hit_location) = $loc && $loc2 ? ($loc,$loc2) : $self->syn_io->get_nearest_position_match($hit,$hit->src1,$loc);
  unless ($ref_location && $hit_location) {
    ($ref_location,$hit_location) = guess_nearest_position_match($hit,$loc,$flip);
  }
  $ref_location && $hit_location || return 0;

  $ref_location -= $hit->start if $ref_location;
  $hit_location -= $hit->tstart if $hit_location;

  my $ref_length = $hit->end - $hit->start;
  my $hit_length = $hit->tend - $hit->tstart;
  my $ref_pixels = $refbox->[2] - $refbox->[0];
  my $hit_pixels = $hitbox->[2] - $hitbox->[0];
  my $ref_conversion = $ref_length/$ref_pixels;
  my $hit_conversion = $hit_length/$hit_pixels || return 0;
  my $ref_pixel = $refbox->[0] + int($ref_location/$ref_conversion + 0.5);
  my $hit_pixel;

  if ($flip) {# && $reversed) {
    $hit_pixel = $hitbox->[2] - int($hit_location/$hit_conversion + 0.5);
  }
  else {
    $hit_pixel = $hitbox->[0] + int($hit_location/$hit_conversion + 0.5);
  }

  $ref_pixel = 0 if $ref_pixel < 0;
  $hit_pixel = 0 if $hit_pixel < 0;
  $hit_pixel = $hitbox->[0] if $hit_pixel < $hitbox->[0];
  $hit_pixel = $hitbox->[2] if $hit_pixel > $hitbox->[2];

  return [$ref_pixel,$hit_pixel];
}

sub grid_coords {
  my ($self,$hit,$refbox,$hitbox,$flip,$segment) = @_;
  
  # don't bother if there are no coords in the database
  return () if $self->syn_io->nomap;

  # exact coordinates if configured
  my $gcoords = $CONF->setting('grid coordinates') || 'AUTO';
  if ($gcoords eq 'exact') {
    return $self->exact_grid_coords(@_);
  } 

  my $step = grid_step($segment) or return;
  my $start = nearest(100,$hit->start);
  $start += $CONF->page_settings("edge") ? $step : 100;

  my @pairs;
  my $offset = $start;
  until ($offset > $hit->end) {
    my $pair = $self->locations2pixels($offset,$hit,$refbox,$hitbox,$flip);
    push @pairs, $pair if $pair;
    $offset += $step;
  }

  return @pairs;
}

# Do not round off or scale, use the grid as provided
sub exact_grid_coords {
  my ($self,$hit,$refbox,$hitbox,$flip,$segment) = @_;

  my $seq_pairs = [$self->syn_io->grid_coords_by_range($hit,$CONF->page_settings->{search_src})];
  $seq_pairs = reorder_pairs($flip,$seq_pairs,1);

  my @pairs;
  for my $s (@$seq_pairs) {
    my $pair = $self->locations2pixels($s->[0],$hit,$refbox,$hitbox,$flip,$s->[1]);
    push @pairs, $pair if $pair;
  }

  return @pairs;
}

# unflip grid-lines for flipped opposite strand panels
sub reorder_pairs {
  my $flip  = shift;
  my $pairs = shift;
  my $force_even = shift;
  
  return $pairs if @$pairs > 1 && @$pairs % 2 && !$force_even;
  return [] if @$pairs == 1;
  return $pairs if !$flip;

  if (@$pairs % 2) {
    shift @$pairs;
  }

  my $new_pairs = [];
  while (my $p1 = shift @$pairs) {
    my $p2 = shift @$pairs;
    push @$new_pairs, [$p1->[0],$p2->[1]];
    push @$new_pairs, [$p2->[0],$p1->[1]];
  }
  return $new_pairs;
}


# will become more sophisticated ?
sub grid_step {
  my $segment = shift;
  return nearest(100,int($segment->length/75)) || 100;
}

sub my_path_info {
  my (undef,$path) = Legacy::Graphics::Browser::Util::_broken_apache_hack();
  my ($src) = $path =~ /([^\/]+)/;
  return $src;
}

sub page_settings {
  my $self = shift;
  my $session
      = Legacy::Graphics::Browser::PageSettings->new( $CONF, param('id') );
  my $source = param('src') || param('source') || my_path_info() || $session->source;
  if (!$source) {
    ($source) = $CONF->sources;
  }

  redirect_legacy_url($source);
  my $old_source    = $session->source($source);
  $CONF->source($source);

  my $settings = $self->get_settings($session);
  return ($settings,$session);
}

sub get_settings {
  my $self = shift;
  my $session = shift;
  my $hash = $session->page_settings;
  default_settings($hash) if param('reset') or !%$hash;
  $self->adjust_settings($hash);
  $hash->{id} = $session->id;
  return $hash;
}

sub default_settings {
  my $settings = shift;
  $settings ||= {};
  $settings->{width}       = $CONF->setting('default width') || $CONF->width;
  $settings->{source}      = $CONF->source;
  $settings->{v}           = $VERSION || '2.0';
  $settings->{grid}        = 1;

  my %default = SETTINGS;
  foreach (keys %default) {
    $settings->{$_} ||= $default{$_};  
  }
  set_default_tracks($settings);
}

sub set_default_tracks {
  my $settings = shift;
  my @labels = $CONF->labels;
  $settings->{tracks} = \@labels;
  foreach (@labels) {
    $settings->{features}{$_} = { visible => 0, options => 0, limit => 0 };
  }
  foreach ( $CONF->default_labels ) {
    $settings->{features}{$_}{visible} = 1;
  }
}

sub _is_checkbox {
  my $option = shift;
  return grep {/$option/} qw/aggregate pgrid shading tiny pflip edge/;
}

sub adjust_settings {
  my $self = shift;
  my $settings = shift;

  if ( param('reset') ) {
    %$settings = ();
    return default_settings($settings);
  }

  $settings->{width} = param('width') if param('width');
  my $divider = $CONF->setting('unit_divider') || 1;

  # Update settings with URL params
  local $^W = 0; # kill uninitialized variable warning
  my %settings = SETTINGS;

  for my $option (keys %settings) {
    next if $option eq 'species';
    my $value = param($option);
    if ($value) {
      $value = undef if $value eq 'off';
      if ($option =~ /start|stop|end/) {
	next unless $value =~ /^[\d-]+/;
      }
      # sigh
      $option = 'stop' if $option eq 'end';
      $settings->{$option} = $value;
    }
  }

  $settings->{name}       ||= "$settings->{ref}:$settings->{start}..$settings->{stop}"
      if defined $settings->{ref} && $settings->{start} && $settings->{stop};

  # expect >1 species
  my @species = param('species');
  if (!@species) {
    $settings->{species} = [keys %{$self->db_map}];
  }
  else {
    $settings->{species} = \@species;
  }

  param( name => $settings->{name} );

  if ( (request_method() eq 'GET' && param('ref'))
       ||
       (param('span') && $divider*$settings->{stop}-$divider*$settings->{start}+1 != param('span'))
       ||
       grep {/left|right|zoom|nav|regionview\.[xy]|overview\.[xy]/} param()
       ) {
    $CONF->zoomnav($settings);
    $settings->{name} = "$settings->{ref}:$settings->{start}..$settings->{stop}";
    param(name => $settings->{name});
  }

  $settings->{name} =~ s/^\s+//; # strip leading
  $settings->{name} =~ s/\s+$//; # and trailing whitespace
  
  return 1;
}


sub _unique {
  my %seen;
  my $src = $CONF->search_src || '';
  my @list = grep {!$seen{$_}++} grep {$_} @_;
  return grep {$_ ne $src} @list;  
}


# nearest function appropriated from Math::Round
sub nearest {
  my $targ = abs(shift);
  my $half = 0.50000000000008;
  my @res  = map {
    if ($_ >= 0) { $targ * int(($_ + $half * $targ) / $targ); }
    else { $targ * POSIX::ceil(($_ - $half * $targ) / $targ); }
  } @_;

  return (wantarray) ? @res : $res[0];
}


# cetralized help via the the GMOD wiki or a defined URL
sub wiki_help {
  my $label = shift;
  my @body  = shift || $label;
  my $url   = HELP;
  (my $blabel = $label) =~ s/_/ /g;
  $label =~ s/\s+/_/g;
  
  return a({ 
	-href => "${url}#${label}", 
	-target => '_wiki_help',
	-onmouseover => "balloon.showTooltip(event,'Click for more information about <b><i>$blabel</i></b>')"},
	@body);
}

sub segment_info {
  my ($settings,$segment) = @_;
  my $whole_segment = $CONF->whole_segment($segment);
  my $padl   = $CONF->setting('pad_left')  || $CONF->image_padding;
  my $padr   = $CONF->setting('pad_right') || $CONF->image_padding;
  my $max    = $CONF->setting('max segment') || MAX_SEGMENT;
  my $width  = ($settings->{width} * OVERVIEW_RATIO);

  hide(image_padding        => $padl);
  hide(max_segment          => $max);
  hide(overview_start       => $whole_segment->start);
  hide(overview_stop        => $whole_segment->end);
  hide(overview_pixel_ratio => $whole_segment->length/$width);
  hide(overview_width       => $width + $padl + $padr);
  hide(detail_start         => $segment->start);
  hide(detail_stop          => $segment->end);
  hide(overview_width       => $width + $padl + $padr);
}

sub hide {
  my ($name,$value) = @_;
  print hidden( -name     => $name,
                -value    => $value,
                -override => 1 ), "\n";
}


########## accessors ###########

sub hits {
    my $self = shift;
    if( @_ ) {
        my $h = $self->{hits} = shift;
        croak 'hits must be an arrayref' unless ref $h eq 'ARRAY';
    }
    return $self->{hits};
}

sub syn_io {
    my $self = shift;
    if( @_ ) {
        $self->{syn_io} = shift;
    }
    return $self->{syn_io};
}

sub invalid_src {
    my $self = shift;
    if( @_ ) {
        $self->{invalid_src} = shift;
    }
    return $self->{invalid_src};
}


######## methods from the erstwhile Legacy::Graphics::Browser::Synteny ##########


## methods for dealing with paths
sub resolve_path {
  my $self = shift;
  my $path      = shift;
  my $path_type = shift; # one of "config" "htdocs" or "url"
  return unless $path;
  return $path if $path =~ m!^/!;           # absolute path
  return $path if $path =~ m!\|\s*$!;       # a pipe
  return $path if $path =~ m!^(http|ftp):!; # an URL
  my $method = ${path_type}."_base";
  $self->can($method) or confess "path_type must be one of 'config','htdocs', or 'url'";
  my $base   = $self->$method or return $path;
  return File::Spec->catfile($base,$path);
}

sub config_path {
  my $self    = shift;
  my $option  = shift;
  $self->resolve_path($self->setting(general => $option),'config');
}

sub htdocs_path {
  my $self    = shift;
  my $option  = shift;
  $self->resolve_path($self->setting(general => $option),'htdocs') 
      || "$ENV{DOCUMENT_ROOT}/gbrowse2";
}

sub url_path {
  my $self    = shift;
  my $option  = shift;
  $self->resolve_path( scalar($self->setting(general => $option)),'url');
}

sub config_base {$ENV{GBROWSE_CONF} 
		    || eval {shift->setting(general=>'config_base')}
			|| GBrowse::ConfigData->config('conf')
		              || '/etc/GBrowse2' }
sub htdocs_base {eval{shift->setting(general=>'htdocs_base')}
                    || GBrowse::ConfigData->config('htdocs')
		        || '/var/www/gbrowse2'     }
sub url_base    {eval{shift->setting(general=>'url_base')}   
                     || basename(GBrowse::ConfigData->config('htdocs'))
		        || '/gbrowse2'             }

sub tmp_base    {eval{shift->setting(general=>'tmp_base')}
                     || GBrowse::ConfigData->config('tmp')
			|| '/tmp' }
sub db_base     {eval{shift->setting(general=>'db_base')}
                    || GBrowse::ConfigData->config('databases')
			|| '//var/www/gbrowse2/databases' }

# these are url-relative options
sub button_url  { shift->url_path('buttons')            }
sub balloon_url { shift->url_path('balloons')           }
sub openid_url  { shift->url_path('openid')             }
sub js_url      { shift->url_path('js')                 }
sub help_url    { shift->url_path('gbrowse_help')       }
sub stylesheet_url   { shift->url_path('stylesheet')    }


# this returns the base URL and path info for use in constructing
# links. For example, if gbrowse is running at http://foo.bar/cgi-bin/gb2/gbrowse/yeast,
# it will return the list ('http://foo.bar/cgi-bin/gb2','yeast')
sub gbrowse_base {
    my $self   = shift;
    my $url    = CGI::url();
    my $source = $self->get_source_from_cgi;
    $source    = CGI::escape($source);
    $url =~   s!/[^/]*$!!;
    return ($url,$source);
}

# this returns the URL of the "master" gbrowse instance
sub gbrowse_url {
    my $self   = shift;
    my ($base,$source) = $self->gbrowse_base;
    return "$base/gbrowse/$source";
}

sub make_path {
    my $self = shift;
    my $path = shift;
    return unless $path =~ /^(.+)$/;
    $path = $1;
    mkpath($path,0,0777) unless -d $path;    
}

sub tmpdir {
    my $self       = shift;
    my @components = @_;
    my $path = File::Spec->catfile($self->tmp_base,@components);
    $self->make_path($path) unless -d $path;
    return $path;
}

sub user_dir {
    my $self       = shift;
    my @components = @_;
    return $self->tmpdir('userdata',@components);
}

sub tmpimage_dir {
    my $self  = shift;
    return $self->tmpdir('images',@_);
}

sub image_url {
    my $self = shift;
    my $path = File::Spec->catfile($self->url_base,'i');
    return $path;
}

sub cache_dir {
    my $self  = shift;
    my $path  = File::Spec->catfile($self->tmp_base,'cache',@_);
    $self->make_path($path) unless -d $path;
    return $path;
}

sub session_locks {
    my $self = shift;
    my $path  = File::Spec->catfile($self->tmp_base,'locks',@_);
    $self->make_path($path) unless -d $path;
    return $path;
}

# return one of
# 'flock'  -- standard flock locking
# 'nfs'    -- use File::NFSLock
# 'mysql'  -- use mysql advisory locks
sub session_locktype {
    my $self = shift;
    return $self->setting(general=>'session lock type') || 'default';
}

sub session_dir {
    my $self = shift;
    my $path  = File::Spec->catfile($self->tmp_base,'sessions',@_);
    $self->make_path($path) unless -d $path;
    return $path;
}

sub slave_dir {
    my $self = shift;
    my $path = $self->setting(general=>'tmp_slave') || '/tmp/gbrowse_slave';
    $self->make_path($path) unless -d $path;
    return $path;
}

sub slave_status_path {
    my $self = shift;
    my $path = File::Spec->catfile($self->tmp_base,'slave_status');
    return $path;
}

# these are relative to the config base
sub plugin_path    { shift->config_path('plugin_path')     }
sub language_path  { shift->config_path('language_path')   }
sub templates_path { shift->config_path('templates_path')  }
sub moby_path      { shift->config_path('moby_path')       }

sub global_timeout         { shift->setting(general=>'global_timeout')      ||  60   }
sub remember_settings_time { shift->setting(general=>'expire session')      || '1M'  }
sub cache_time             { shift->setting(general=>'expire cache')        || '2h'  }
sub upload_time            { shift->setting(general=>'expire uploads')      || '6w'  }
sub datasources_expire     { shift->setting(general=>'expire data sources') || '10m' }
sub url_fetch_timeout      { shift->setting(general=>'url_fetch_timeout')            }
sub url_fetch_max_size     { shift->setting(general=>'url_fetch_max_size')           }

sub application_name       { shift->setting(general=>'application_name')      || 'GBrowse'                    }
sub application_name_long  { shift->setting(general=>'application_name_long') || 'The Generic Genome Browser' }
sub email_address          { shift->setting(general=>'email_address')         || 'noreply@gbrowse.com'        }
sub smtp                   { shift->setting(general=>'smtp_gateway')          || 'smtp.res.oicr.on.ca'        }
sub user_account_db        { shift->setting(general=>'user_account_db')       
				   || 'DBI:mysql:gbrowse_login;user=gbrowse;password=gbrowse'  }
sub admin_account          { shift->setting(general=>'admin_account') }
sub admin_dbs              { shift->setting(general=>'admin_dbs')     }
sub openid_secret {
    return GBrowse::ConfigData->config('OpenIDConsumerSecret')
}

# uploads
sub upload_db_adaptor {
    my $self = shift;
    return $self->setting(general=>'upload_db_adaptor') || $self->setting(general=>'userdb_adaptor');
}
sub upload_db_host {
    my $self = shift;
    return $self->setting(general=>'upload_db_host') || $self->setting(general=>'userdb_host') || 'localhost'
}
sub upload_db_user {
    my $self = shift;
    return $self->setting(general=>'upload_db_user') || $self->setting(general=>'userdb_user') || '';
}
sub upload_db_pass {
    my $self = shift;
    return $self->setting(general=>'upload_db_pass') || $self->setting(general=>'userdb_pass') || '';
}

sub session_driver {
    my $self = shift;
    my $driver = $self->setting(general=>'session driver');
    return $driver if $driver;

    $HAS_DBFILE = eval "require DB_File; 1" || 0
	unless defined $HAS_DBFILE;
    $HAS_STORABLE = eval "require Storable; 1" || 0
	unless defined $HAS_STORABLE;

    my $sdriver    = $HAS_DBFILE ? 'db_file' : 'file';
    my $serializer = $HAS_STORABLE ? 'storable' : 'default';

    return "driver:$sdriver;serializer:$serializer";
}

sub session_args    {
  my $self = shift;
  my %args = shellwords($self->setting(general=>'session args')||'');
  return \%args if %args;
  return {Directory=>$self->session_dir};
}

## methods for dealing with data sources

sub data_source_description {
  my $self = shift;
  my $dsn  = shift;
  return $self->setting($dsn=>'description');
}

sub data_source_show {
    my $self = shift;
    my $dsn  = shift;
    return if $self->setting($dsn=>'hide');
    return $self->authorized($dsn);
}

sub data_source_path {
  my $self = shift;
  my $dsn  = shift;
  my ($regex_key) = grep { $dsn =~ /^$_$/ } map { $_ =~ s/^=~//; $_ } grep { $_ =~ /^=~/ } keys(%{$self->{config}});
  if ($regex_key) {
      my $path = $self->resolve_path($self->setting("=~".$regex_key=>'path'),'config');
      my @matches = ($dsn =~ /$regex_key/);
      for (my $i = 1; $i <= scalar(@matches); $i++) {
	  $path =~ s/\$$i/$matches[$i-1]/;
      }
      return $self->resolve_path($path, 'config');
  }
  my $path = $self->setting($dsn=>'path') or return;
  $self->resolve_path($path,'config');
}

sub create_data_source {
  my $self = shift;
  my $dsn  = shift;
  my $path = $self->data_source_path($dsn) or return;
  my ($regex_key) = grep { $dsn =~ /^$_$/ } map { $_ =~ s/^=~//; $_ } grep { $_ =~ /^=~/ } keys(%{$self->{config}});
  my $name = $dsn;
  if ($regex_key) { $dsn = "=~".$regex_key; }

  my $source_class =
      'Bio::Graphics::Browser2::DataSource'
     .( $self->setting( $dsn => 'type' ) eq 'synteny' ? '::Synteny' : '' );

  my $source = $source_class->new(
      $path,
      $name,
      $self->data_source_description($dsn),
      $self) or return;

  if (my $adbs = $self->admin_dbs) {
      my $path  = File::Spec->catfile($adbs,$dsn);
      my $expr = "$path/*/*.conf";
      $source->add_conf_files($expr);
  }
  return $source;
}

sub default_source {
  my $self    = shift;
  my $source  = $self->setting(general => 'default source');
  return $source if $self->valid_source($source);
  return ( $self->globals->data_sources )[0];
}

sub valid_source {
  my $self            = shift;
  my $proposed_source = shift;

  if (!exists($self->{config}{$proposed_source})) {
    my ($regex_key) = grep { $proposed_source =~ /^$_$/ } map { $_ =~ s/^=~//; $_ } grep { $_ =~ /^=~/ } keys(%{$self->{config}});
    return unless $regex_key;
    my $path =  $self->data_source_path("=~" . $regex_key) or return;
    return -e $path || $path =~ /\|\s*$/;
  }

  return unless exists $self->{config}{$proposed_source};
  my $path =  $self->data_source_path($proposed_source) or return;
  return -e $path || $path =~ /\|\s*$/;
}

sub get_source_from_cgi {
    my $self = shift;

    my $source = CGI::param('source') || CGI::param('src') || CGI::path_info();
    $source    =~ s!\#$!!;  # get rid of trailing # left by IE
    $source    =~ s!^/+!!;  # get rid of leading & trailing / from path_info()
    $source    =~ s!/+$!!;
    
    $source;
}

sub update_data_source {
  my $self    = shift;
  my $session    = shift;
  my $new_source = shift;
  my $old_source = $session->source || $self->default_source;

  $new_source ||= $self->get_source_from_cgi();

  my $source;
  if ($self->valid_source($new_source)) {
    $session->source($new_source);
    $source = $new_source;
  } else {
    carp "Invalid source $new_source";
    my $fallback_source = $self->valid_source($old_source) 
	? $old_source
	: $self->default_source;
    $session->source($fallback_source);
    $source = $fallback_source;
  }

  return $source;
}

sub time2sec {
    my $self = shift;
    my $time  = shift;
    $time =~ s/\s*#.*$//; # strip comments

    my(%mult) = ('s'=>1,
                 'm'=>60,
                 'h'=>60*60,
                 'd'=>60*60*24,
                 'w'=>60*60*24*7,
                 'M'=>60*60*24*30,
                 'y'=>60*60*24*365);
    my $offset = $time;
    if (!$time || (lc($time) eq 'now')) {
	$offset = 0;
    } elsif ($time=~/^([+-]?(?:\d+|\d*\.\d*))([smhdwMy])/) {
	$offset = ($mult{$2} || 1)*$1;
    }
    return $offset;
}

sub authorized_session {
  my $self                     = shift;
  my ($id,$authority) = @_;

  $id       ||= undef;
  my $session = $self->session($id);

  return $session unless $session->private;

  if ($session->match_nonce($authority,CGI::remote_addr())) {
      return $session;
  } else {
      warn "UNAUTHORIZED ATTEMPT";
      return $self->session('xyzzy');
  }
}

1;
