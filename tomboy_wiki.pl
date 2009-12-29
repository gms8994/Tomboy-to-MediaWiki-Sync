#!/usr/bin/perl -w

use strict;

use MediaWiki::API;
use Config::Abstract::Ini;
use File::Slurp;
use XML::Twig;
use Date::Manip;

my $INIFILENAME = "tomboy_wiki.ini";
my $INIDIR;

### set up the proper ini directory
if ($^O eq 'MSWin32') {
	$INIDIR = $ENV{'APPDATA'};
	$INIDIR =~ s/(?<!\\)$/\\/;
} else {
	$INIDIR = $ENV{'HOME'};
	$INIDIR =~ s|(?<!)/$|/|;
}

my $INIFILE;
if (! -f $INIDIR . $INIFILENAME) {
	$INIFILE = "./" . $INIFILENAME;
} else {
	$INIFILE = $INIDIR . $INIFILENAME;
}

my $settings = new Config::Abstract::Ini($INIFILE);
my $username = $settings->get_entry_setting('wiki', 'username');
my $password = $settings->get_entry_setting('wiki', 'password');

my $path = $settings->get_entry_setting('tomboy', 'path');
$path =~ s/~/$ENV{'HOME'}/ if defined($ENV{'HOME'});
$path =~ s/%(.*?)%/$ENV{$1}/;

if ($^O eq 'MSWin32') {
	$path =~ s/(?<!\\)$/\\/;
} else {
	$path =~ s|(?<!/)$|/|;
}

my $mw = MediaWiki::API->new();
$mw->{config}->{api_url} = $settings->get_entry_setting('wiki', 'url');
$mw->login( { lgname => $username, lgpassword => $password } );

my %notes_by_title = ();

###########
### HANDLE NOTES THAT HAVE BEEN DELETED ON THE WIKI
###########
my $ref = $mw->list( {
    action => 'query',
    list => 'logevents',
    letype => 'delete',
});

foreach my $item (@$ref) {
    ### each of these is potentially a tomboy note.  see if we can find it
    my $title = $item->{'title'};

    my $res = &find_note_by_title($title);
    if ($res =~ /^0$/) { next; }

    ### delete the file
    warn "Removing $res locally";
    delete($notes_by_title{$title});
    unlink($res);
}
###########
### FINISHED DELETING LOCAL NOTES
###########

###########
### HANDLE NOTES DELETED LOCALLY
###########

###########
### For now, the wiki is "sacred".  Nothing will be deleted from there for *not* existing in Tomboy
### We're just skipping this stage.
###########
# $ref = $mw->list( {
#     action => 'query',
#     list => 'search',
#     srwhat => 'text',
#     srsearch => '{{tomboy',
# });
# 
# foreach my $item (@$ref) {
# 
#     my $title = $item->{'title'};
# 
#     my $res = &find_note_by_title($title);
#     if ($res =~ /^0$/) {
#         ### doesn't exist locally.  delete from wiki
#         warn "Removing $title from wiki";
#         $mw->edit( {
#             action => 'delete',
#             title => $title,
#             reason => 'Deleted from Tomboy locally',
#         } ) || warn $mw->{error}->{code} . ': ' . $mw->{error}->{details};
#     }
# }

###########
### FINISHED DELETING WIKI NOTES
###########

### find note files
my @files = read_dir($path);
@files = grep { /\.note$/ } @files;

### loop note files, and update as needed
foreach my $file (@files) {
    ### check to see if a wiki page already exists with this title
    
    (my $uuid = $file) =~ s/\.note$//;
    $file = $path . $file;

    my $t = XML::Twig->new();
    $t->parsefile($file);

    my $root = $t->root;
    my $title = $root->first_child('title')->text;
    my $last_change_date = $root->first_child('last-change-date')->text;

    ## see if we can find the page based on it's uuid
    my $ref = $mw->list( {
        action => 'query',
        list => 'search',
        srwhat => 'text',
        srsearch => $uuid,
    });

    if (ref $ref eq 'ARRAY') {
        ## this one already exists on the server.  compare timestamps to see which should be modified

        my $wiki_last_mod = ParseDate($ref->[0]->{'timestamp'});
        my $tomboy_last_mod = ParseDate($last_change_date);

        my $wiki_updated = Date_Cmp($wiki_last_mod, $tomboy_last_mod);

        use Data::Dumper;
        warn Dumper( [ $wiki_last_mod, $tomboy_last_mod ] );

        if ($wiki_updated == 1) {
            &update_note($uuid, $t, $ref);
        } elsif ($wiki_updated == -1) {
            undef($t);
            &update_wiki($uuid, $root, $ref);
        } else {
            ## do nothing.  neither has been updated
        }

    } else {
        &update_wiki($uuid, $root);
    }

}

$mw->logout();

sub update_wiki {
    my ($uuid, $xml, $ref) = @_;

    warn "Updating wiki file $uuid";

    ### note file is newer; update the wiki

    my $title = $xml->first_child('title')->text;
    my $last_change_date = $xml->first_child('last-change-date')->text;
    my $last_metadata_change_date = $xml->first_child('last-metadata-change-date')->text;
    my $text = $xml->first_child('text')->first_child('note-content')->inner_xml;
    my $create_date = $xml->first_child('create-date')->text;
    my $cursor_position = $xml->first_child('cursor-position')->text;
    my $width = $xml->first_child('width')->text;
    my $height = $xml->first_child('height')->text;
    my $x = $xml->first_child('x')->text;
    my $y = $xml->first_child('y')->text;
    my $open_on_startup = $xml->first_child('open-on-startup')->text;
    my @tags = ();
    if ($xml->first_child('tags')) {
        @tags = $xml->first_child('tags')->children('tag');
    }

    my $template = <<END;
{{tomboy|
|uuid=$uuid
|last_change_date=$last_change_date
|last_metadata_change_date=$last_metadata_change_date
|create_date=$create_date
|cursor_position=$cursor_position
|width=$width
|height=$height
|x=$x
|y=$y
|open_on_startup=$open_on_startup
}}
END

    my $tags = '';

    if (scalar(@tags) > 0) {
        foreach my $tag (@tags) {
            $tags .= " [[Category:" . $tag->text . "]]";
        }
        $tags =~ s/system:notebook://g;
    }

    $text =~ s/<link:internal>(.*?)<\/link:internal>/\[\[$1\]\]/g;
    $text =~ s/<link:url>(.*?)<\/link:url>/\[$1\]/g;
    $text =~ s/<size:huge>(.*?)<\/size:huge>/== $1 ==/g;
    $text =~ s/<size:large>(.*?)<\/size:large>/=== $1 ===/g;

    $text =~ s/<list-item.*?>/* /g;
    $text =~ s/<\/list-item>//g;
    $text =~ s/<\/?list>//g;

    my $res = $mw->edit( {
        action => 'edit',
        title => $title,
        basetimestamp => $ref->[0]->{'timestamp'},
        text => $text . "\n\n" . $template . "\n\n" . $tags,
    } );
}

sub update_note {
    my ($uuid, $xml, $wiki_data) = @_;

    warn "Updating note file $uuid";

    my $t = $xml;
    $xml = $t->root;

    ### wiki is newer, update the note file
    my $page = $mw->get_page( { title => $wiki_data->[0]->{'title'} } );

    while ($page->{'*'} =~ /REDIRECT \[\[(.*)\]\]/) {
        $page = $mw->get_page( { title => $1 } );
        warn "Redirect found, handling";
    }

    my @categories = ();

    my $text = $page->{'*'};
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;

    $text =~ s/\n\n{{tomboy.*?}}//s;
    while ($text =~ s/(?!\n\n )?\[\[Category:(.*?)\]\]//) {
        push(@categories, $1);
    }
    $text =~ s/\[\[(.*?)\]\]/<link:internal>$1<\/link:internal>/g;
    $text =~ s/\[(.*?)\]/<link:url>$1<\/link:url>/g;
    $text =~ s/=== (.*?) ===/<size:large>$1<\/size:large>/g;
    $text =~ s/== (.*?) ==/<size:huge>$1<\/size:huge>/g;

    my $tags;

    if (! $xml->first_child('tags')) {
        $tags = $xml->new('tags');
    } else {
        $tags = $xml->first_child('tags');
    }

    foreach my $cat (@categories) {
        $tags->new('tag')->set_text('system:notebook:' . $cat);
    }

    ### handle lists
    my @data = split(/\n/, $text);
    my @new_data = ();
    my $list_open = 0;
    foreach my $s (@data) {
        if ($s =~ /^\* / && $list_open == 0) {
            $s =~ s/^\* /<list><list-item dir="ltr">/;
            $s =~ s/$/<\/list-item>/;
            $list_open = 1;
        } elsif ($s =~ /^\* / && $list_open == 1) {
            $s =~ s/^\* /<list-item dir="ltr">/;
            $s =~ s/$/<\/list-item>/;
        } elsif ($s !~ /^\* / && $list_open == 1) {
            $s =~ s/^/<\/list>/;
            $list_open = 0;
        }
        push(@new_data, $s);
    }
    if ($list_open == 1) { push(@new_data, "</list>"); }

    $text = join("\n", @new_data);
    $text =~ s/<\/list-item>/\n<\/list-item>/g;

    ### tomboy uses the first line as a "checksum" of sorts for the title
    ### make sure it's updated as well
    $text =~ s/^.*\n/$page->{'title'}\n/;

    my $title = $page->{'title'};
    my $timestamp = UnixDate($page->{'timestamp'}, '%O%z');

    $xml->first_child('title')->set_text($title);
    $xml->first_child('text')->first_child('note-content')->set_inner_xml($text);
    $xml->first_child('last-change-date')->set_text($timestamp);
    $xml->first_child('last-metadata-change-date')->set_text($timestamp);

    $t->print_to_file( $path . $uuid . '.note');

    undef($xml);
    undef($t);
}

sub find_note_by_title {
    my ($title) = @_;

    if (defined($notes_by_title{$title})) { return $notes_by_title{$title}; }

    my @files = read_dir($path);
    @files = grep { /\.note$/ } @files;

    foreach my $file (@files) {
        $file = $path . $file;
        open(FILE, "<$file") || next;
        my @contents = <FILE>;
        close(FILE);
        my $contents = join("", @contents);

        if ($contents =~ /<title>(.*?)<\/title>/) {
            $notes_by_title{$1} = $file;
        }
    }

    if (defined($notes_by_title{$title})) { return $notes_by_title{$title}; }

    return 0;
}
