package pgFormatter::Beautify;

use strict;
use warnings;
use warnings qw( FATAL );
use Encode qw( decode );

use Text::Wrap;

our $DEBUG = 0;

# PostgreSQL functions that use a FROM clause
our @have_from_clause = qw( extract overlay substring trim );

=head1 NAME

pgFormatter::Beautify - Library for pretty-printing SQL queries

=head1 VERSION

Version 4.0

=cut

# Version of pgFormatter
our $VERSION = '4.1dev';

# Inclusion of code from Perl package SQL::Beautify
# Copyright (C) 2009 by Jonas Kramer
# Published under the terms of the Artistic License 2.0.

=head1 SYNOPSIS

This module can be used to reformat given SQL query, optionally anonymizing parameters.

Output can be either plain text, or it can be HTML with appropriate styles so that it can be displayed on a web page.

Example usage:

    my $beautifier = pgFormatter::Beautify->new();
    $beautifier->query( 'select a,b,c from d where e = f' );

    $beautifier->beautify();
    my $nice_txt = $beautifier->content();

    $beautifier->format('html');
    $beautifier->beautify();
    my $nice_html = $beautifier->content();

    $beautifier->format('html');
    $beautifier->anonymize();
    $beautifier->beautify();
    my $nice_anonymized_html = $beautifier->content();

    $beautifier->format();
    $beautifier->beautify();
    $beautifier->wrap_lines()
    my $wrapped_txt = $beautifier->content();

=head1 FUNCTIONS

=head2 new

Generic constructor - creates object, sets defaults, and reads config from given hash with options.

Takes options as hash. Following options are recognized:

=over

=item * break - String that is used for linebreaks. Default is "\n".

=item * colorize - if set to false CSS style will not be applied to html output. Used internally to display errors in CGI mode withour style.

=item * comma - set comma at beginning or end of a line in a parameter list

=over

=item end - put comma at end of the list (default)

=item start - put comma at beginning of the list

=back

=item * comma_break - add new-line after each comma in INSERT statements

=item * format - set beautify format to apply to the content (default: text)

=over

=item text - output content as plain/text (command line mode default)

=item html - output text/html with CSS style applied to content (CGI mode default)

=back

=item * functions - list (arrayref) of strings that are function names

=item * keywords - list (arrayref) of strings that are keywords

=item * no_comments - if set to true comments will be removed from query

=item * placeholder - use the specified regex to find code that must not be changed in the query.

=item * query - query to beautify

=item * rules - hash of rules - uses rule semantics from SQL::Beautify

=item * space - character(s) to be used as space for indentation

=item * spaces - how many spaces to use for indentation

=item * uc_functions - what to do with function names:

=over

=item 0 - do not change

=item 1 - change to lower case

=item 2 - change to upper case

=item 3 - change to Capitalized

=back

=item * separator - string used as dynamic code separator, default is single quote.

=item * uc_keywords - what to do with keywords - meaning of value like with uc_functions

=item * wrap - wraps given keywords in pre- and post- markup. Specific docs in SQL::Beautify

=item * format_type - try an other formatting

=item * wrap_limit - wrap queries at a certain length

=item * wrap_after - number of column after which lists must be wrapped

=back

For defaults, please check function L<set_defaults>.

=cut

sub new {
    my $class   = shift;
    my %options = @_;

    my $self = bless {}, $class;
    $self->set_defaults();

    for my $key ( qw( query spaces space break wrap keywords functions rules uc_keywords uc_functions no_comments placeholder separator comma comma_break format colorize format_type wrap_limit wrap_after) ) {
        $self->{ $key } = $options{ $key } if defined $options{ $key };
    }

    $self->_refresh_functions_re();

    # Make sure "break" is sensible
    $self->{ 'break' } = ' ' if $self->{ 'spaces' } == 0;

    # Initialize internal stuff.
    $self->{ '_level' } = 0;

    # Array to store placeholders values
    @{ $self->{ 'placeholder_values' } } = ();

    # Hash to store dynamic code
    %{ $self->{ 'dynamic_code' } } = ();

    # Check comma value, when invalid set to default: end
    if (lc($self->{ 'comma' }) ne 'start') {
        $self->{ 'comma' } = 'end';
    } else {
        $self->{ 'comma' } = lc($self->{ 'comma' });
    }

    $self->{ 'format' } //= 'text';
    $self->{ 'colorize' } //= 1;

    $self->{ 'format_type' } //= 0;
    $self->{ 'wrap_limit' } //= 0;
    $self->{ 'wrap_after' } //= 0;

    return $self;
}

=head2 query

Accessor to query string. Both reads:

    $object->query()

, and writes

    $object->query( $something )

=cut

sub query {
    my $self      = shift;
    my $new_value = shift;

    $self->{ 'query' } = $new_value if defined $new_value;

    my $i = 0;
    my %temp_placeholder = ();
    my @temp_content = split(/(CREATE(?:\s+OR\s+REPLACE)?\s+(?:FUNCTION|PROCEDURE)\s+)/i, $self->{ 'query' });
    if ($#temp_content > 0) {
        for (my $j = 0; $j <= $#temp_content; $j++) {
            next if ($temp_content[$j] =~ /^CREATE/i);
	    # Remove any call too CREATE/DROP LANGUAGE to not break search of function code separator
	    $temp_content[$j] =~ s/(CREATE|DROP)\s+LANGUAGE\s+[^;]+;.*//is;
	    # Fix case where code separator with $ is associated to begin/end keywords
	    $temp_content[$j] =~ s/([^\s]+\$)(BEGIN\s)/$1 $2/igs;
	    $temp_content[$j] =~ s/(\sEND)(\$[^\s]+)/$1 $2/igs;
	    $temp_content[$j] =~ s/(CREATE|DROP)\s+LANGUAGE\s+[^;]+;.*//is;
            my $fctname = '';
            if ($temp_content[$j] =~ /^([^\s\(]+)/) {
                $fctname = lc($1);
            }
            next if (!$fctname);
            my $language = 'sql';
            if ($temp_content[$j] =~ /\s+LANGUAGE\s+[']*([^'\s;]+)[']*/i) {
                $language = lc($1);
            }
            # if the function language is not SQL or PLPGSQL
            if ($language !~ /^(?:plpg)?sql$/) {
                # Try to find the code separator
	        my $tmp_str = $temp_content[$j];
                while ($tmp_str =~ s/\s+AS\s+([^\s]+)\s+//is) {
                    my $code_sep = quotemeta($1);
		    foreach my $k (@{ $self->{ 'keywords' } }) {
			    last if ($code_sep =~ s/\b$k$//i); 
		    }
		    next if (!$code_sep);
                    if ($tmp_str =~ /\s+$code_sep[\s;]+/) {
                        while ( $temp_content[$j] =~ s/($code_sep(?:.+?)$code_sep)/CODEPART${i}CODEPART/s) {
                            push(@{ $self->{ 'placeholder_values' } }, $1);
                            $i++;
                        }
		        last;
                    }
                }
            }
        }
    }
    $self->{ 'query' } = join('', @temp_content);

    # Store values of code that must not be changed following the given placeholder
    if ($self->{ 'placeholder' }) {
        while ( $self->{ 'query' } =~ s/($self->{ 'placeholder' })/PLACEHOLDER${i}PLACEHOLDER/) {
            push(@{ $self->{ 'placeholder_values' } }, $1);
            $i++;
       }
    }

    # Replace dynamic code with placeholder
    $self->_remove_dynamic_code( \$self->{ 'query' }, $self->{ 'separator' } );

    # Replace operator with placeholder
    $self->_quote_operator( \$self->{ 'query' } );

    return $self->{ 'query' };
}

=head2 content

Accessor to content of results. Must be called after $object->beautify().

This can be either plain text or html following the format asked by the
client with the $object->format() method.

=cut

sub content
{
    my $self      = shift;
    my $new_value = shift;

    $self->{ 'content' } = $new_value if defined $new_value;
    $self->{ 'content' } =~ s/\(\s+\(/\(\(/gs;

    # Replace placeholders with their original dynamic code
    $self->_restore_dynamic_code( \$self->{ 'content' } );

    # Replace placeholders with their original operator
    $self->_restore_operator( \$self->{ 'content' } );

    # Replace placeholders by their original values
    if ($#{ $self->{ 'placeholder_values' } } >= 0)
    {
        $self->{ 'content' } =~ s/PLACEHOLDER(\d+)PLACEHOLDER/$self->{ 'placeholder_values' }[$1]/igs;
        $self->{ 'content' } =~ s/CODEPART(\d+)CODEPART/$self->{ 'placeholder_values' }[$1]/igs;
    }

    return $self->{ 'content' };
}

=head2 highlight_code

Makes result html with styles set for highlighting.

=cut

sub highlight_code
{
    my ($self, $token, $last_token, $next_token) = @_;

    # Do not use uninitialized variable
    $last_token //= '';
    $next_token //= '';

    # Colorize operators
    while ( my ( $k, $v ) = each %{ $self->{ 'dict' }->{ 'symbols' } } ) {
        if ($token eq $k) {
            $token = '<span class="sy0">' . $v . '</span>';
            return $token;
        }
    }

    # lowercase/uppercase keywords taking care of function with same name
    if ( $self->_is_keyword( $token ) && (!$self->_is_function( $token ) || $next_token ne '(') ) {
        if ( $self->{ 'uc_keywords' } == 1 ) {
            $token = '<span class="kw1_l">' . $token . '</span>';
        } elsif ( $self->{ 'uc_keywords' } == 2 ) {
            $token = '<span class="kw1_u">' . $token . '</span>';
        } elsif ( $self->{ 'uc_keywords' } == 3 ) {
            $token = '<span class="kw1_c">' . $token . '</span>';
        } else {
            $token = '<span class="kw1">' . $token . '</span>';
        }
        return $token;
    }

    # lowercase/uppercase known functions or words followed by an open parenthesis
    # if the token is not a keyword, an open parenthesis or a comment
    if (($self->_is_function( $token ) && $next_token eq '(')
	    || (!$self->_is_keyword( $token ) && !$next_token eq '('
		    && $token ne '(' && !$self->_is_comment( $token )) ) {
        if ($self->{ 'uc_functions' } == 1) {
            $token = '<span class="kw2_l">' . $token . '</span>';
        } elsif ($self->{ 'uc_functions' } == 2) {
            $token = '<span class="kw2_u">' . $token . '</span>';
        } elsif ($self->{ 'uc_functions' } == 3) {
            $token = '<span class="kw2_c">' . $token . '</span>';
        } else {
            $token = '<span class="kw2">' . $token . '</span>';
        }
        return $token;
    }

    # Colorize STDIN/STDOUT in COPY statement
    if ( grep(/^\Q$token\E$/i, @{ $self->{ 'dict' }->{ 'copy_keywords' } }) ) {
        if ($self->{ 'uc_keywords' } == 1) {
            $token = '<span class="kw3_!">' . $token . '</span>';
        } elsif ($self->{ 'uc_keywords' } == 2) {
            $token = '<span class="kw3_u">' . $token . '</span>';
        } elsif ($self->{ 'uc_keywords' } == 3) {
            $token = '<span class="kw3_c">' . $token . '</span>';
        } else {
            $token = '<span class="kw3">' . $token . '</span>';
        }
        return $token;
    }

    # Colorize parenthesis
    if ( grep(/^\Q$token\E$/i, @{ $self->{ 'dict' }->{ 'brackets' } }) ) {
        $token = '<span class="br0">' . $token . '</span>';
        return $token;
    }

    # Colorize comment
    if ( $self->_is_comment( $token ) ) {
        $token = '<span class="br1">' . $token . '</span>';
        return $token;
    }

    # Colorize numbers
    $token =~ s/\b(\d+)\b/<span class="nu0">$1<\/span>/igs;

    # Colorize string
    $token =~ s/('.*?(?<!\\)')/<span class="st0">$1<\/span>/gs;
    $token =~ s/(`[^`]*`)/<span class="st0">$1<\/span>/gs;

    return $token;
}

=head2 tokenize_sql

Splits input SQL into tokens

Code lifted from SQL::Beautify

=cut

sub tokenize_sql {
    my $self  = shift;
    my $query = $self->query();

    my $re = qr{
        (
                (?:\\(?:copyright|errverbose|g|gx|gexec|gset|q|crosstabview|watch|\?|h|e|ef|ev|p|r|s|w|copy|echo|i|ir|o|qecho|if|elif|else|endif|d(?:[aAbcCdDfFgilLmnoOpstTuvExy]|dp|et|es|eu|ew|fa|fn|ft|fw|Fd|Fp|Ft|rds|Rp|Rs)?S?\+?|l\+?|sf\+?|sv\+?|z|a|C|f|H|pset|t|T|x|c|connect|encoding|password|conninfo|cd|setenv|timing|\!|prompt|set|unset|lo_export|lo_import|lo_list|lo_unlink))(?:$|[\n]|[\ \t](?:(?!\\\\)[\ \t\S])*)        # psql meta-command
                |
                (?:\s*--)[\ \t\S]*      # single line comments
                |
                (?:\-\|\-) # range operator "is adjacent to"
                |
                (?:\->>|\->|\#>>|\#>|\?\&|\?)  # Json Operators
                |
                (?:\#<=|\#>=|\#<>|\#<|\#=) # compares tinterval and reltime
                |
                (?:>>=|<<=) # inet operators
                |
                (?:!!|\@\@\@) # deprecated factorial and full text search  operators
                |
                (?:\|\|\/|\|\/) # square root and cube root
                |
                (?:\@\-\@|\@\@|\#\#|<\->|<<\||\|>>|\&<\||\&<|\|\&>|\&>|<\^|>\^|\?\#|\#|\?<\||\?\-\||\?\-|\?\|\||\?\||\@>|<\@|\~=)
                                 # Geometric Operators
                |
                (?:~<=~|~>=~|~>~|~<~) # string comparison for pattern matching operator families
                |
                (?:!~~|!~~\*|~~\*|~~) # LIKE operators
                |
                (?:!~\*|!~|~\*) # regular expression operators
                |
                (?:\*=|\*<>|\*<=|\*>=|\*<|\*>) # composite type comparison operators
                |
                (?:<>|<=>|>=|<=|=>|==|!=|:=|=|!|<<|>>|<|>|\|\||\||&&|&|-|\+|\*(?!/)|/(?!\*)|\%|~|\^|\?) # operators and tests
                |
                [\[\]\(\),;.]            # punctuation (parenthesis, comma)
                |
                E\'\'(?!\')              # empty single escaped quoted string
                |
                \'\'(?!\')              # empty single quoted string
                |
                \"\"(?!\"")             # empty double quoted string
                |
                "(?>(?:(?>[^"\\]+)|""|\\.)*)+" # anything inside double quotes, ungreedy
                |
                `(?>(?:(?>[^`\\]+)|``|\\.)*)+` # anything inside backticks quotes, ungreedy
                |
                E'(?>(?:(?>[^'\\]+)|''|\\.)*)+' # anything escaped inside single quotes, ungreedy.
                |
                '(?>(?:(?>[^'\\]+)|''|\\.)*)+' # anything inside single quotes, ungreedy.
                |
                /\*[\ \t\r\n\S]*?\*/      # C style comments
                |
                (?:[\w:\@]+[\$]*[\w:\@]*(?:\.(?:\w+|\*)?)*) # words, standard named placeholders, db.table.*, db.*
                |
                (?:\$\w+\$)
                |
                (?: \$_\$ | \$\d+ | \${1,2} | \$\w+\$ ) # dollar expressions - eg $_$ $3 $$ $BODY$
                |
                \n                      # newline
                |
                [\t\ ]+                 # any kind of white spaces
        )
    }smx;

    my @query = ();
    @query = grep { /\S/ } $query =~ m{$re}smxg;
    $self->{ '_tokens' } = \@query;

    return @query;
}

=head2 beautify

Beautify SQL.

After calling this function, $object->content() will contain nicely indented result.

Code lifted from SQL::Beautify

=cut

sub beautify {
    my $self = shift;

    # Use to store the token position in the array
    my $pos = 0;

    # Main variables used to store differents state
    $self->content( '' );
    $self->{ '_level' } = 0;
    $self->{ '_level_stack' } = [];
    $self->{ '_level_parenthesis' } = [];
    $self->{ '_new_line' }    = 1;
    $self->{ '_current_sql_stmt' } = '';
    $self->{ '_is_meta_command' } = 0;
    $self->{ '_fct_code_delimiter' } = '';
    $self->{ '_first_when_in_case' } = 0;

    $self->{ '_is_in_conversion' } = 0;
    $self->{ '_is_in_case' } = 0;
    $self->{ '_is_in_where' } = 0;
    $self->{ '_is_in_from' } = 0;
    $self->{ '_is_in_join' } = 0;
    $self->{ '_is_in_create' } = 0;
    $self->{ '_is_in_rule' } = 0;
    $self->{ '_is_in_create_function' } = 0;
    $self->{ '_is_in_alter' } = 0;
    $self->{ '_is_in_trigger' } = 0;
    $self->{ '_is_in_publication' } = 0;
    $self->{ '_is_in_call' } = 0;
    $self->{ '_is_in_type' } = 0;
    $self->{ '_is_in_declare' } = 0;
    $self->{ '_is_in_block' } = -1;
    $self->{ '_is_in_work' } = 0;
    $self->{ '_is_in_function' } = 0;
    $self->{ '_is_in_procedure' } = 0;
    $self->{ '_is_in_index' } = 0;
    $self->{ '_is_in_with' }  = 0;
    $self->{ '_is_in_explain' }  = 0;
    $self->{ '_parenthesis_level' } = 0;
    $self->{ '_parenthesis_function_level' } = 0;
    $self->{ '_has_order_by' }  = 0;
    $self->{ '_has_over_in_join' } = 0;
    $self->{ '_insert_values' } = 0;
    $self->{ '_is_in_constraint' } = 0;
    $self->{ '_is_in_distinct' } = 0;
    $self->{ '_is_in_array' } = 0;
    $self->{ '_is_in_filter' } = 0;
    $self->{ '_parenthesis_filter_level' } = 0;
    $self->{ '_is_in_within' } = 0;
    $self->{ '_is_in_grouping' } = 0;
    $self->{ '_is_in_partition' } = 0;
    $self->{ '_is_in_over' } = 0;
    $self->{ '_is_in_policy' } = 0;
    $self->{ '_is_in_using' } = 0;
    $self->{ '_and_level' } = 0;
    $self->{ '_col_count' } = 0;
    $self->{ '_is_in_drop' } = 0;
    $self->{ '_is_in_operator' } = 0;
    $self->{ '_is_in_exception' } = 0;
    $self->{ '_is_in_sub_query' } = 0;
    $self->{ '_is_in_fetch' } = 0;
    $self->{ '_is_in_aggregate' } = 0;
    $self->{ '_is_in_value' } = 0;
    $self->{ '_parenthesis_level_value' } = 0;

    my $last = '';
    my @token_array = $self->tokenize_sql();

    while ( defined( my $token = $self->_token ) )
    {
        my $rule = $self->_get_rule( $token );

	# Replace concat operator found in some SGBD into || for normalization
	if (lc($token) eq 'concat' && defined $self->_next_token() && $self->_next_token ne '(') {
		$token = '||';
	}

        ####
        # Find if the current keyword is a known function name
        ####
        if (defined $last && $last && defined $self->_next_token and $self->_next_token eq '(') {
            my $word = lc($token);
            $word =~ s/^[^\.]+\.//;
            $word =~ s/^:://;
            if (uc($last) eq 'FUNCTION' and $token =~ /^\d+$/) {
                $self->{ '_is_in_function' }++;
	    } elsif ($word && exists $self->{ 'dict' }->{ 'pg_functions' }{$word}) {
                $self->{ '_is_in_function' }++;
            # Try to detect user defined functions
	    } elsif ($last ne '*' and !$self->_is_keyword($token)
			    and (exists $self->{ 'dict' }->{ 'symbols' }{ $last }
				    or $last =~ /^\d+$/)
	    )
	    {
                $self->{ '_is_in_function' }++;
	    }
        }

        ####
        # Set open parenthesis position to know if we
        # are in subqueries or function parameters
        ####
        if ( $token eq ')')
        {
	    $self->{ '_parenthesis_filter_level' }-- if ($self->{ '_is_in_filter' } and $self->{ '_parenthesis_filter_level' });
	    $self->{ '_is_in_filter' } = 0 if (!$self->{ '_parenthesis_filter_level' });

            if (!$self->{ '_is_in_function' }) {
                $self->{ '_parenthesis_level' }-- if ($self->{ '_parenthesis_level' } > 0);
            } else {
                $self->{ '_parenthesis_function_level' }-- if ($self->{ '_parenthesis_function_level' } > 0);
                if (!$self->{ '_parenthesis_function_level' }) {
	            $self->{ '_level' } = pop(@{ $self->{ '_level_parenthesis_function' } }) || 0;
		    $self->_over($token,$last) if (!$self->{ '_is_in_operator' } && !$self->{ '_is_in_alter' });
	        }
            }
	    $self->{ '_is_in_function' } = 0 if (!$self->{ '_parenthesis_function_level' });

	    if (!$self->{ '_parenthesis_level' } && $self->{ '_is_in_sub_query' }) {
		$self->{ '_is_in_sub_query' }--;
		$self->_back($token, $last);
	    }
            if ($self->{ '_is_in_value' }) {
                $self->{ '_parenthesis_level_value' }-- if ($self->{ '_parenthesis_level_value' });
	    }
        }
        elsif ( $token eq '(')
        {
	    $self->{ '_parenthesis_filter_level' }++ if ($self->{ '_is_in_filter' });
            if ($self->{ '_is_in_function' }) {
                $self->{ '_parenthesis_function_level' }++;
	        push(@{ $self->{ '_level_parenthesis_function' } } , $self->{ '_level' }) if ($self->{ '_parenthesis_function_level' } == 1);
            } else {
                if (!$self->{ '_parenthesis_level' } && $self->{ '_is_in_from' }) {
                    push(@{ $self->{ '_level_parenthesis' } } , $self->{ '_level' });
                }
                $self->{ '_parenthesis_level' }++;
                if ($self->{ '_is_in_value' }) {
                    $self->{ '_parenthesis_level_value' }++;
		}
            }

	    if (defined $self->_next_token and $self->_next_token =~ /^(SELECT|WITH)$/i) {
		$self->{ '_is_in_sub_query' }++ if (defined $last and uc($last) ne 'AS');
	    }
        }

        ####
        # Control case where we have to add a newline, go back and
        # reset indentation after the last ) in the WITH statement
        ####
        if ($token =~ /^WITH$/i && (!defined $last || $last ne ')')
		&& !$self->{ '_is_in_partition' } && !$self->{ '_is_in_publication' }
		&& !$self->{ '_is_in_policy' })
	{
		$self->{ '_is_in_with' } = 1 if (!$self->{ '_is_in_using' } && uc($self->_next_token) ne 'ORDINALITY' && uc($last) ne 'START');
		$self->{ 'no_break' } = 1 if (uc($self->_next_token) eq 'ORDINALITY');
        }
        elsif ($token =~ /^WITH$/i && uc($self->_next_token) eq 'ORDINALITY')
	{
		$self->{ 'no_break' } = 1;
	}
        elsif ($token =~ /^(AS|IS)$/i && defined $self->_next_token && $self->_next_token eq '(')
	{
            $self->{ '_is_in_with' }++ if ($self->{ '_is_in_with' } == 1);
        }
        elsif ($self->{ '_is_in_create' } && $token =~ /^AS$/i && defined $self->_next_token && uc($self->_next_token) eq 'SELECT')
	{
            $self->{ '_is_in_create' } = 0;
        }
        elsif ( $token eq '[' )
	{
            $self->{ '_is_in_array' }++;
        }
        elsif ( $token eq ']' )
	{
            $self->{ '_is_in_array' }-- if ($self->{ '_is_in_array' });
	}
        elsif ( $token eq ')' )
	{
            $self->{ '_has_order_by' } = 0;
	    if ($self->{ '_is_in_distinct' }) {
                    $self->_add_token( $token );
                    $self->_new_line($token,$last);
		    $self->{ '_is_in_distinct' } = 0;
		    $last = $token;
		    next;
	    }

            $self->{ '_is_in_using' } = 0 if ($self->{ '_is_in_using' } && !$self->{ '_parenthesis_level' });

	    if ($self->{ '_is_in_create' } > 1 and defined $self->_next_token && uc($self->_next_token) eq 'AS' && !$self->{ '_is_in_with'}) {
                $self->_new_line($token,$last);
	    }
            if (($self->{ '_is_in_with' } > 1 || $self->{ '_is_in_operator' }) && !$self->{ '_parenthesis_level' }
		    && !$self->{ '_is_in_alter' } && !$self->{ '_is_in_policy' }) {
                $self->_new_line($token,$last) if (!$self->{ '_is_in_operator' } ||
			(!$self->{ '_is_in_drop' } and $self->_next_token eq ';'));
		if (!$self->{ '_is_in_operator' }) {
                    $self->{ '_level' } = pop(@{ $self->{ '_level_stack' } }) || 0;
                    $self->_back($token, $last);
	        }
                $self->_add_token( $token );
		if (!$self->{ '_is_in_operator' }) {
                    @{ $self->{ '_level_stack' } } = ();
                    $self->{ '_level' } = 0;
                    $self->{ 'break' } = ' ' unless ( $self->{ 'spaces' } != 0 );
	        }
                if ($self->{ '_is_in_with' }) {
                    if (defined $self->_next_token && $self->_next_token eq ',') {
                        $self->{ '_is_in_with' } = 1;
                    } else {
                        $self->{ '_is_in_with' } = 0;
                    }
                }
		$last = $token;
                next;
            }
	}
	elsif (defined $self->_next_token && $self->_next_token eq '(')
	{
            $self->{ '_is_in_filter' } = 1 if (uc($token) eq 'FILTER');
	    $self->{ '_is_in_grouping' } = 1 if ($token =~ /^GROUPING|ROLLUP$/i);
        } 
        elsif ( uc($token) eq 'PASSING' and defined $self->_next_token && uc($self->_next_token) eq 'BY')
	{
            $self->{ '_has_order_by' } = 1;
        } 

	# Explain need indentation in option list
        if ( uc($token) eq 'EXPLAIN' )
	{
	    $self->{ '_is_in_explain' }  = 1;
        } 

        ####
        # Set the current kind of statement parsed
        ####
        if ($token =~ /^(FUNCTION|PROCEDURE|SEQUENCE|INSERT|DELETE|UPDATE|SELECT|RAISE|ALTER|GRANT|REVOKE|COMMENT|DROP|RULE|COMMENT)$/i) {
            my $k_stmt = uc($1);
	    $self->{ '_is_in_explain' }  = 0;
            # Set current statement with taking care to exclude of SELECT ... FOR UPDATE statement.
            if ($k_stmt ne 'UPDATE' or (defined $self->_next_token and $self->_next_token ne ';' and $self->_next_token ne ')')) {
                if ($k_stmt !~ /^UPDATE|DELETE$/i || !$self->{ '_is_in_create' }) {
                    $self->{ '_current_sql_stmt' } = $k_stmt if ($self->{ '_current_sql_stmt' } !~ /^(GRANT|REVOKE)$/i and !$self->{ '_is_in_trigger' } and !$self->{ '_is_in_operator' } && !$self->{ '_is_in_alter' });
                }
            }
        }

        ####
        # Mark that we are in CREATE statement that need newline
        # after a comma in the parameter, declare or column lists.
        ####
        if ($token =~ /^(FUNCTION|PROCEDURE)$/i and $self->{ '_is_in_create' } and !$self->{'_is_in_trigger'}) {
		$self->{ '_is_in_create_function' } = 1;
	} elsif ($token =~ /^(FUNCTION|PROCEDURE)$/i and $self->{'_is_in_trigger'}) {
		$self->{ '_is_in_index' } = 1;
	}
        if ($token =~ /^CREATE$/i && $self->_next_token !~ /^(EVENT|UNIQUE|INDEX|EXTENSION|TYPE|PUBLICATION|OPERATOR|RULE|CONVERSION|DOMAIN)$/i) {
	    $self->{ '_is_in_create' } = 1;
        } elsif ($token =~ /^CREATE$/i && $self->_next_token =~ /^RULE$/i) {
	    $self->{ '_is_in_rule' } = 1;
        } elsif ($token =~ /^CREATE$/i && $self->_next_token =~ /^EVENT$/i) {
	    $self->{ '_is_in_trigger' } = 1;
        } elsif ($token =~ /^CREATE$/i && $self->_next_token =~ /^TYPE$/i) {
            $self->{ '_is_in_type' } = 1;
        } elsif ($token =~ /^CREATE$/i && $self->_next_token =~ /^PUBLICATION$/i) {
            $self->{ '_is_in_publication' } = 1;
        } elsif ($token =~ /^CREATE$/i && $self->_next_token =~ /^CONVERSION$/i) {
	    $self->{ '_is_in_conversion' } = 1;
        } elsif ($token =~ /^CREATE|DROP$/i && $self->_next_token =~ /^OPERATOR$/i) {
	    $self->{ '_is_in_operator' } = 1;
            $self->{ '_is_in_drop' } = 1 if ($token =~ /^DROP$/i);
        } elsif ($token =~ /^ALTER$/i) {
            $self->{ '_is_in_alter' }++;
        } elsif ($token =~ /^DROP$/i){
            $self->{ '_is_in_drop' } = 1;
        } elsif ($token =~ /^VIEW$/i and $self->{ '_is_in_create' }) {
            $self->{ '_is_in_index' } = 1;
	    $self->{ '_is_in_create' } = 0;
        } elsif ($token =~ /^AGGREGATE$/i and $self->{ '_is_in_create' }) {
            $self->{ '_is_in_aggregate' } = 1;
            $self->{ '_has_order_by' } = 1;
        } elsif ($token =~ /^EVENT$/i && $self->_next_token =~ /^TRIGGER$/i) {
	    $self->_over($token, $last);
            $self->{ '_is_in_index' } = 1;
        }

	if ($self->{ '_is_in_using' } and defined $self->_next_token and $self->_next_token =~ /^OPERATOR|AS$/i) {
		$self->{ '_is_in_using' } = 0;
	}

        if ($token =~ /^ALTER$/i and $self->{ '_is_in_alter' } > 1) {
	    $self->_new_line($token,$last);
	    $self->_over($token, $last) if ($last ne ',');
            $self->_add_token( $token );
            $last = $token;
            next;
        }

	####
	# Mark that we are in a CALL statement to remove any new line
	####
	if ($token =~ /^CALL/i) {
	    $self->{ '_is_in_call' } = 1;
	}

	# Increment operator tag to add newline in alter operator statement
        if (($self->{ '_is_in_alter' } or uc($last) eq 'AS') and uc($token) eq 'OPERATOR') {
	    $self->_new_line($token,$last) if (uc($last) eq 'AS' and uc($token) eq 'OPERATOR');
	    $self->{ '_is_in_operator' }++;
        }

        ####
        # Mark that we are in index/constraint creation statement to
        # avoid inserting a newline after comma and AND/OR keywords.
        # This also used in SET statement taking care that we are not
        # in update statement. CREATE statement are not subject to this rule
        ####
        if (! $self->{ '_is_in_create' } and $token =~ /^(INDEX|PRIMARY|CONSTRAINT)$/i) {
            $self->{ '_is_in_index' } = 1;
        } elsif (! $self->{ '_is_in_create' } and uc($token) eq 'SET') {
            $self->{ '_is_in_index' } = 1 if ($self->{ '_current_sql_stmt' } ne 'UPDATE');
        } elsif ($self->{ '_is_in_create' } and (uc($token) eq 'UNIQUE' or (uc($token) eq 'PRIMARY' and uc($self->_next_token) eq 'KEY'))) {
		$self->{ '_is_in_constraint' } = 1;
	}

        # Same as above but for ALTER FUNCTION/PROCEDURE/SEQUENCE or when
        # we are in a CREATE FUNCTION/PROCEDURE statement
        elsif ($token =~ /^(FUNCTION|PROCEDURE|SEQUENCE)$/i and !$self->{'_is_in_trigger'}) {
            $self->{ '_is_in_index' } = 1 if (uc($last) eq 'ALTER' and !$self->{ '_is_in_operator' } and !$self->{ '_is_in_alter' });
            if ($token =~ /^FUNCTION$/i && ($self->{ '_is_in_create' } || $self->{ '_current_sql_stmt' } eq 'COMMENT')) {
                $self->{ '_is_in_index' } = 1 if (!$self->{ '_is_in_operator' });
	    } elsif ($token =~ /^PROCEDURE$/i && $self->{ '_is_in_create' }) {
                $self->{ '_is_in_index' } = 1;
		$self->{ '_is_in_procedure' } = 1;
            }
        }
        # Desactivate index like formatting when RETURN(S) keyword is found
        elsif ($token =~ /^(RETURN|RETURNS)$/i) {
            $self->{ '_is_in_index' } = 0;
        } elsif ($token =~ /^AS$/i) {
            if ( !$self->{ '_is_in_index' } and $self->{ '_is_in_from' } and $last eq ')' and uc($token) eq 'AS' and $self->_next_token() eq '(') {
                $self->{ '_is_in_index' } = 1;
            } else {
                $self->{ '_is_in_index' } = 0;
            }
	    $self->{ '_is_in_block' } = 1 if ($self->{ '_is_in_procedure' });
	    $self->{ '_is_in_over' } = 0;
        }
	if ($token =~ /^BEGIN|DECLARE$/i) {
            $self->{ '_is_in_create' }-- if ($self->{ '_is_in_create' });
	}
    
        ####
        # Mark statements that use string_agg() or group_concat() function
        # as statement that can have an ORDER BY clause inside the call to
        # prevent applying order by formatting.
        ####
        if ($token =~ /^(string_agg|group_concat|array_agg|percentile_cont)$/i) {
            $self->{ '_has_order_by' } = 1;
        } elsif ( $token =~ /^(?:GENERATED)$/i and $self->_next_token =~ /^ALWAYS|BY$/i ) {
            $self->{ 'no_break' } = 1;
        } elsif ( $token =~ /^(?:TRUNCATE)$/i ) {
            $self->{ 'no_break' } = 1;
        } elsif ( uc($token) eq 'IDENTITY' ) {
            $self->{ '_has_order_by' } = 0;
            $self->{ 'no_break' } = 0;
        } elsif ( $self->{ '_has_order_by' } and uc($token) eq 'ORDER' and $self->_next_token =~ /^BY$/i) {
	    $self->_add_token( $token, $last );
            $last = $token;
            next;
        } elsif ($self->{ '_has_order_by' } and uc($token) eq 'BY') {
            $self->_add_token( $token );
            $last = $token;
            next;
        }
        elsif ($token =~ /^OVER$/i)
	{
            $self->_add_token( $token );
	    $self->{ '_is_in_over' } = 1;
	    $self->{ '_has_order_by' } = 1;
            $last = $token;
            next;
	}

	# Fix case where we don't knwon if we are outside a SQL function
	if (defined $last and uc($last) eq 'AS'and defined $self->_next_token and $self->_next_token eq ';'
			and $self->{ '_is_in_create_function' }) {
		$self->{ '_is_in_create_function' } = 0;
	}

        ####
        # Set function code delimiter, it can be any string found after
        # the AS keyword in function or procedure creation code
        ####
        # Toogle _fct_code_delimiter to force next token to be stored as the function code delimiter
        if (uc($token) eq 'AS' and (!$self->{ '_fct_code_delimiter' } || $self->_next_token =~ /CODEPART/)
                               and $self->{ '_current_sql_stmt' } =~ /^(FUNCTION|PROCEDURE)$/i)
        {
            if ($self->{ '_is_in_create' })
	    {
                $self->_new_line($token,$last);
                $self->_add_token( $token );
		@{ $self->{ '_level_stack' } } = ();
		$self->{ '_level' } = 0;
		$self->{ 'break' } = ' ' unless ( $self->{ 'spaces' } != 0 );
                $self->{ '_is_in_create' } = 0;
	    } else {
                $self->_add_token( $token );
            }
	    if ($self->_next_token !~ /CODEPART/ || $self->_next_token =~ /^'/)
	    {
                $self->{ '_fct_code_delimiter' } = '1';
	    }
            $self->{ '_is_in_create' } = 0;
            $last = $token;
            next;
        }
        elsif ($token =~ /^INSTEAD$/i and defined $last and uc($last) eq 'DO')
	{
                $self->_add_token( $token );
                $self->_new_line($token,$last);
                $last = $token;
                next;
        }
        elsif ($token =~ /^DO$/i and defined $self->_next_token and $self->_next_token =~ /^INSTEAD$/i)
	{
                $self->_new_line($token,$last);
		$self->_over($token,$last);
                $self->_add_token( $token );
                $last = $token;
                next;
        }
        elsif ($token =~ /^DO$/i and !$self->{ '_fct_code_delimiter' } and $self->_next_token =~ /^\$[^\s]*/)
	{
                $self->{ '_fct_code_delimiter' } = '1';
		$self->{ '_is_in_create_function' } = 1;
                $self->_new_line($token,$last) if ($self->{ 'content' } !~ /\n$/s);
                $self->_add_token( $token );
                $last = $token;
                next;
	}

        # Store function code delimiter
        if ($self->{ '_fct_code_delimiter' } eq '1')
	{
	    if ($self->_next_token =~ /CODEPART/) {
                $self->{ '_fct_code_delimiter' } = '0';
	    } else {
	        $self->{ '_fct_code_delimiter' } = $token;
	    }
            $self->_add_token( $token );
            $last = $token;
            $self->_new_line($token,$last);
            $self->_over($token,$last) if (defined $self->_next_token && $self->_next_token !~ /^(DECLARE|BEGIN)$/i);
            next;
        }

        # Desactivate the block mode when code delimiter is found for the second time
        if ($self->{ '_fct_code_delimiter' } && $token eq $self->{ '_fct_code_delimiter' })
	{
            $self->{ '_is_in_block' } = -1;
            $self->{ '_is_in_exception' } = 0;
            @{ $self->{ '_level_stack' } } = ();
            $self->{ '_level' } = 0;
            $self->{ 'break' } = ' ' unless ( $self->{ 'spaces' } != 0 );
            $self->{ '_fct_code_delimiter' } = '';
            $self->{ '_current_sql_stmt' } = '';
            $self->_new_line($token,$last);
            $self->_add_token( $token );
            $last = $token;
            next;
        }

        ####
        # Mark when we are parsing a DECLARE or a BLOCK section. When
        # entering a BLOCK section store the current indentation level
        ####
        if (uc($token) eq 'DECLARE' and $self->{ '_is_in_create_function' }) {
            $self->{ '_is_in_block' } = -1;
            $self->{ '_is_in_exception' } = 0;
            $self->{ '_is_in_declare' } = 1;
            @{ $self->{ '_level_stack' } } = ();
            $self->{ '_level' } = 0;
            $self->{ 'break' } = ' ' unless ( $self->{ 'spaces' } != 0 );
            $self->_new_line($token,$last);
            $self->_add_token( $token );
            $self->_new_line($token,$last);
            $self->_over($token,$last);
            $last = $token;
	    $self->{ '_is_in_create_function' } = 0;
            next;
        }
        elsif ( uc($token) eq 'BEGIN' )
	{
            $self->{ '_is_in_declare' } = 0;
            if ($self->{ '_is_in_block' } == -1) {
                @{ $self->{ '_level_stack' } } = ();
                $self->{ '_level' } = 0;
                $self->{ 'break' } = ' ' unless ( $self->{ 'spaces' } != 0 );
            } else {
                # Store current indent position to print END at the right level
                push @{ $self->{ '_level_stack' } }, $self->{ '_level' };
            }
            $self->_new_line($token,$last);
            $self->_add_token( $token );
	    if (defined $self->_next_token && $self->_next_token !~ /^(WORK|TRANSACTION|ISOLATION|;)$/i) {
		$self->_new_line($token,$last);
		$self->_over($token,$last);
                $self->{ '_is_in_block' }++;
            }
	    $self->{ '_is_in_work' } = 1 if (defined $self->_next_token && $self->_next_token =~ /^(WORK|TRANSACTION|ISOLATION|;)$/i);
            $last = $token;
            next;
        }
        elsif ( $token =~ /^(COMMIT|ROLLBACK)$/i and (not defined $last or uc($last) ne 'ON'))
	{
	    $self->{ '_is_in_work' } = 0;
	    $self->{ '_is_in_declare' } = 0;
	    $self->_new_line($token,$last);
	    $self->{ '_level' } = pop( @{ $self->{ '_level_stack' } } ) || 0;
            $self->_add_token( $token );
            $last = $token;
            next;
        }
        elsif ( $token =~ /^FETCH$/i and defined $last and $last eq ';')
	{
	    $self->_new_line($token,$last);
	    $self->_back($token, $last) if ($self->{ '_is_in_block' } == -1);
            $self->_add_token( $token );
            $last = $token;
	    $self->{ '_is_in_fetch' } = 1;
            next;
        }

        ####
        # Special case where we want to add a newline into ) AS (
        ####
        if (uc($token) eq 'AS' and $last eq ')' and $self->_next_token eq '(')
	{
            $self->_new_line($token,$last);
        }
        # and before RETURNS with increasing indent level
	elsif (uc($token) eq 'RETURNS')
	{
            $self->_new_line($token,$last);
            $self->_over($token,$last);
        }
        # and before WINDOW
	elsif (uc($token) eq 'WINDOW')
	{
            $self->_new_line($token,$last);
	    $self->{ '_level' } = pop( @{ $self->{ '_level_stack' } } ) || 0;
            $self->_add_token( $token );
            $last = $token;
	    $self->{ '_has_order_by' } = 1;
	    next;
        }

	# Treated DISTINCT as a modifier of the whole select clause, not only the first column only
	if (uc($token) eq 'ON' && defined $last && uc($last) eq 'DISTINCT')
	{
            $self->{ '_is_in_distinct' } = 1;
            $self->_over($token,$last);
        }
        elsif (uc($token) eq 'DISTINCT' && defined $last && uc($last) eq 'SELECT' && defined $self->_next_token && $self->_next_token !~ /^ON$/i)
        {
            $self->_add_token( $token );
            $self->_new_line($token,$last) if (!$self->{'wrap_after'});
            $self->_over($token,$last);
            $last = $token;
	    next;
        }

        if ( $rule )
	{
            $self->_process_rule( $rule, $token );
        }

        elsif ($token =~ /^(LANGUAGE|SECURITY|COST)$/i && !$self->{ '_is_in_alter' } && !$self->{ '_is_in_drop' } )
	{
            $self->_new_line($token,$last) if (uc($token) ne 'SECURITY' or (defined $last and uc($last) ne 'LEVEL'));
            $self->_add_token( $token );
        }
        elsif ($token =~ /^PARTITION$/i && !$self->{ '_is_in_over' } && defined $last && $last ne '(')
	{
	    $self->{ '_is_in_partition' } = 1;
            if ($self->{ '_is_in_create' } && defined $last and $last eq ')')
	    {
                $self->_new_line($token,$last);
	        $self->{ '_level' } = pop( @{ $self->{ '_level_stack' } } ) || 0;
                $self->_add_token( $token );
	    }
	    else
	    {
                $self->_add_token( $token );
            }
        }
        elsif ($token =~ /^POLICY$/i)
	{
            $self->{ '_is_in_policy' } = 1;
            $self->_add_token( $token );
            $last = $token;
	    next;
        }
        elsif ($token =~ /^TRIGGER$/i and defined $last and uc($last) eq 'CREATE')
	{
            $self->{ '_is_in_trigger' } = 1;
            $self->_add_token( $token );
            $last = $token;
	    next;
        }
        elsif ($token =~ /^(BEFORE|AFTER)$/i and $self->{ '_is_in_trigger' })
	{
            $self->_new_line($token,$last);
            $self->_over($token,$last);
            $self->_add_token( $token );
            $last = $token;
	    next;
        }
        elsif ($token =~ /^EXECUTE$/i and ($self->{ '_is_in_trigger' } or (defined $last and uc($last) eq 'AS')))
	{
            $self->_new_line($token,$last);
            $self->_add_token( $token );
            $last = $token;
	    next;
        }
        elsif ( $token eq '(' )
	{
	    if ($self->{ '_is_in_aggregate' } && defined $self->_next_token and ($self->_is_keyword($self->_next_token) or $self->_is_sql_keyword($self->_next_token)) and uc($self->_next_token) ne 'VARIADIC') {
		$self->{ '_is_in_aggregate' } = 0;
                $self->{ '_has_order_by' } = 0;
	    }
            $self->{ '_is_in_create' }++ if ($self->{ '_is_in_create' });
            $self->{ '_is_in_constraint' }++ if ($self->{ '_is_in_constraint' });
            $self->_add_token( $token, $last );
	    if (defined $self->_next_token and $self->_next_token eq ')' and !$self->{ '_is_in_create' }) {
		 $last = $token;
		 next;
	    }
            if ( !$self->{ '_is_in_index' } && !$self->{ '_is_in_publication' }
		    && !$self->{ '_is_in_distinct' } && !$self->{ '_is_in_filter' }
		    && !$self->{ '_is_in_grouping' } && !$self->{ '_is_in_partition' }
		    && !$self->{ '_is_in_over' } && !$self->{ '_is_in_trigger' }
		    && !$self->{ '_is_in_policy' } && !$self->{ '_is_in_aggregate' }
		    && !$self->{ 'no_break' }
	    ) {
                if (uc($last) eq 'AS' || $self->{ '_is_in_create' } == 2 || uc($self->_next_token) eq 'CASE')
		{
                    $self->_new_line($token,$last) if ((!$self->{'_is_in_function'} or $self->_next_token =~ /^CASE$/i) and $self->_next_token ne ')' and $self->_next_token !~ /^(PARTITION|ORDER)$/i);
                }
                if ($self->{ '_is_in_with' } == 1 or $self->{ '_is_in_explain' }) {
                    $self->_over($token,$last);
                    $self->_new_line($token,$last) if (!$self->{ 'wrap_after' });
		    $last = $token if (!$self->{ '_is_in_explain' } || $self->{ 'wrap_after' });
                    next;
                }
		if (!$self->{ '_is_in_if' } and !$self->{ '_is_in_alter' } and (!$self->{ '_is_in_function' } or $last ne '('))
		{
		    $self->_over($token,$last) if ($self->{ '_is_in_operator' } <= 2);
		    if (!$self->{ '_is_in_function' } and !$self->_is_type($self->_next_token)) {
		        if ($self->{ '_is_in_operator' } == 1) {
			    $self->_new_line($token,$last);
		            $self->{ '_is_in_operator' }++;
		        } elsif ($self->{ '_is_in_type' }) {
                            $self->_new_line($token,$last);
		        }
		    }
                    $last = $token;
		}
                if ($self->{ '_is_in_type' } == 1) {
                    $last = $token;
                    next;
                }
            }

	    if ($self->{ 'format_type' } && $self->{ '_current_sql_stmt' } =~ /FUNCTION|PROCEDURE/i
		    && $self->{ '_is_in_create' } == 2
		    && (not defined $self->_next_token or $self->_next_token ne ')')
	    ) {
                $self->_over($token,$last) if ($self->{ '_is_in_block' } < 0);
                $self->_new_line($token,$last);
                next;
	    }
        }

        elsif ( $token eq ')' )
	{
	    if ($self->{ '_is_in_constraint' } and defined $self->_next_token
			    and ($self->_next_token eq ',' or $self->_next_token eq ')')) {
		$self->{ '_is_in_constraint' } = 0;
	    }
            if ($self->{ '_is_in_with' } == 1 || $self->{ '_is_in_explain' }) {
                $self->_back($token, $last);
	        $self->_new_line($token,$last) if (!$self->{ 'wrap_after' });
                $self->_add_token( $token );
		$self->{ '_is_in_explain' } = 0;
                next;
            }
	    if ($self->{ 'format_type' } && $self->{ '_current_sql_stmt' } =~ /FUNCTION|PROCEDURE/i
		    && $self->{ '_is_in_create' } == 2
	    ) {
                $self->_back($token, $last) if ($self->{ '_is_in_block' } < 0);
                $self->_new_line($token,$last) if (defined $last && $last ne '(');
	    }
            if ($self->{ '_is_in_index' } || $self->{ '_is_in_alter' }
		    || $self->{ '_is_in_partition' } || $self->{ '_is_in_policy' }
		    || (defined $self->_next_token and $self->_next_token =~ /^OVER$/i)
	    ) {
                $self->_add_token( '' );
                $self->_add_token( $token );
		$self->{ '_is_in_over' } = 0 if (!$self->{ '_parenthesis_level' });
                $last = $token;
                $self->{ '_is_in_create' }-- if ($self->{ '_is_in_create' });
                next;
            }
	    if (defined $self->_next_token && $self->_next_token !~ /FILTER/i)
	    {

                my $add_nl = 0;
                $add_nl = 1 if ($self->{ '_is_in_create' } > 1
		    and defined $last and $last ne '('
                    and (not defined $self->_next_token or $self->_next_token =~ /^PARTITION|;$/i or ($self->_next_token =~ /^ON$/i and !$self->{ '_parenthesis_level' }))
                );
                $add_nl = 1 if ($self->{ '_is_in_type' } == 1
		    and $self->_next_token !~ /^AS$/i
                    and (not defined $self->_next_token or $self->_next_token eq ';')
                );
                $add_nl = 1 if ($self->{ '_current_sql_stmt' } ne 'INSERT'
			    and !$self->{ '_is_in_function' }
			    and (defined $self->_next_token 
				    and $self->_next_token =~ /^(SELECT|WITH)$/i)
			    and ($self->{ '_is_in_create' } or $last ne ')' and $last ne ']')
	        );
		$self->_new_line($token,$last) if ($add_nl);
                $self->_back($token, $last) if (!$self->{ '_is_in_grouping' }
			&& !$self->{ '_is_in_trigger' } && !$self->{ 'no_break' }
		);
                $self->{ '_is_in_create' }-- if ($self->{ '_is_in_create' });
                $self->{ '_is_in_type' }-- if ($self->{ '_is_in_type' });
	    }
	    if (!$self->{ '_parenthesis_level' }) {
                $self->{ '_is_in_filter' } = 0;
                $self->{ '_is_in_within' } = 0;
                $self->{ '_is_in_grouping' } = 0;
                $self->{ '_is_in_over' } = 0;
                $self->{ '_has_order_by' } = 0;
                $self->{ '_is_in_policy' } = 0;
                $self->{ '_is_in_where' } = 0;
                $self->{ '_is_in_aggregate' } = 0;
            } 
            $self->_add_token( $token );
            # Do not go further if this is the last token
            if (not defined $self->_next_token) {
                $last = $token;
                next;
            }

            # When closing CTE statement go back again
            if ($self->_next_token =~ /^SELECT|INSERT|UPDATE|DELETE$/i && !$self->{ '_is_in_policy' }) {
                $self->_back($token, $last);
            }
            if ($self->{ '_is_in_create' } <= 1) {
                my $next_tok = quotemeta($self->_next_token);
                $self->_new_line($token,$last)
                    if (defined $self->_next_token
                    and $self->_next_token !~ /^AS|IS|THEN|INTO|BETWEEN|ON|FILTER|WITHIN$/i
                    and ($self->_next_token !~ /^AND|OR$/i or !$self->{ '_is_in_if' })
                    and $self->_next_token ne ')'
                    and $self->_next_token !~ /^:/
                    and $self->_next_token ne ';'
                    and $self->_next_token ne ','
                    and $self->_next_token ne '||'
                    and ($self->_is_keyword($self->_next_token) or $self->_is_function($self->_next_token))
		    and $self->{ '_current_sql_stmt' } !~ /^(GRANT|REVOKE)$/
                    and !exists  $self->{ 'dict' }->{ 'symbols' }{ $next_tok }
                );
            }
        }

        elsif ( $token eq ',' )
	{
            my $add_newline = 0;
	    $self->{ '_is_in_constraint' } = 0 if ($self->{ '_is_in_constraint' } == 1);
	    $self->{ '_col_count' }++ if (!$self->{ '_is_in_function' });
            if (($self->{ '_is_in_over' } or $self->{ '_has_order_by' }) and !$self->{ '_parenthesis_level' } and !$self->{ '_parenthesis_function_level' })
	    {
		    $self->{ '_is_in_over' } = 0;
		    $self->{ '_has_order_by' } = 0;
		    $self->_back($token, $last);
	    }
            $add_newline = 1 if ( !$self->{ 'no_break' }
                               && !$self->{ '_is_in_function' }
			       && !$self->{ '_is_in_distinct' }
			       && !$self->{ '_is_in_array' }
                               && ($self->{ 'comma_break' } || $self->{ '_current_sql_stmt' } ne 'INSERT')
                               && ($self->{ '_current_sql_stmt' } ne 'RAISE')
                               && ($self->{ '_current_sql_stmt' } !~ /^(FUNCTION|PROCEDURE)$/
				       || $self->{ '_fct_code_delimiter' } ne '')
                               && !$self->{ '_is_in_where' }
                               && !$self->{ '_is_in_drop' }
                               && !$self->{ '_is_in_index' }
                               && !$self->{ '_is_in_aggregate' }
			       && !$self->{ '_is_in_alter' }
			       && !$self->{ '_is_in_publication' }
			       && !$self->{ '_is_in_call' }
			       && !$self->{ '_is_in_policy' }
			       && !$self->{ '_is_in_grouping' }
			       && !$self->{ '_is_in_partition' }
			       && ($self->{ '_is_in_constraint' } <= 1)
			       && $self->{ '_is_in_operator' } != 1
			       && !$self->{ '_has_order_by' }
                               && $self->{ '_current_sql_stmt' } !~ /^(GRANT|REVOKE)$/
                               && $self->_next_token !~ /^('$|\s*\-\-)/i
                               && !$self->{ '_parenthesis_function_level' }
			       && (!$self->{ '_col_count' } or $self->{ '_col_count' } > ($self->{ 'wrap_after' } - 1))
                               || ($self->{ '_is_in_with' } and !$self->{ 'wrap_after' })
                    );
            $self->{ '_col_count' } = 0 if ($self->{ '_col_count' } > ($self->{ 'wrap_after' } - 1));
	    $add_newline = 0 if ($self->{ '_is_in_using' } and $self->{ '_parenthesis_level' });
	    $add_newline = 0 if ($self->{ 'no_break' });

            if ($self->{ '_is_in_with' } >= 1 && !$self->{ '_parenthesis_level' }) {
                $add_newline = 1 if (!$self->{ 'wrap_after' });
            }
	    if ($self->{ 'format_type' } && $self->{ '_current_sql_stmt' } =~ /FUNCTION|PROCEDURE/i && $self->{ '_is_in_create' } == 2) {
                $add_newline = 1;
	    }
            if ($self->{ '_is_in_alter' } && $self->{ '_is_in_operator' } >= 2) {
		$add_newline = 1 if (defined $self->_next_token and $self->_next_token =~ /^OPERATOR|FUNCTION$/i);
	    }
            $self->_new_line($token,$last) if ($add_newline && $self->{ 'comma' } eq 'start');
            $self->_add_token( $token );
	    $add_newline = 0 if ($self->{ '_is_in_value' } and $self->{ '_parenthesis_level_value' });
	    $self->_new_line($token,$last) if ($add_newline && $self->{ 'comma' } eq 'end');
        }

        elsif ( $token eq ';' or $token =~ /^\\(?:g|crosstabview|watch)/ ) { # statement separator or executing psql meta command (prefix 'g' includes all its variants)

            $self->_add_token($token);

            if ($self->{ '_is_in_rule' }) {
		$self->_back($token, $last);
	    }
	    elsif ($self->{ '_is_in_create' } && $self->{ '_is_in_block' } > -1)
	    {
	        $self->{ '_level' } = pop( @{ $self->{ '_level_stack' } } ) || 0;
	    }

            # Initialize most of statement related variables
            $self->{ 'no_break' } = 0;
            $self->{ '_is_in_where' } = 0;
            $self->{ '_is_in_from' } = 0;
            $self->{ '_is_in_join' } = 0;
            $self->{ '_is_in_create' } = 0;
            $self->{ '_is_in_alter' } = 0;
	    $self->{ '_is_in_rule' } = 0;
            $self->{ '_is_in_publication' } = 0;
            $self->{ '_is_in_call' } = 0;
            $self->{ '_is_in_type' } = 0;
            $self->{ '_is_in_function' } = 0;
            $self->{ '_is_in_prodedure' } = 0;
            $self->{ '_is_in_index' } = 0;
            $self->{ '_is_in_if' } = 0;
            $self->{ '_is_in_with' } = 0;
            $self->{ '_has_order_by' } = 0;
            $self->{ '_has_over_in_join' } = 0;
            $self->{ '_parenthesis_level' } = 0;
            $self->{ '_parenthesis_function_level' } = 0;
	    $self->{ '_is_in_constraint' } = 0;
	    $self->{ '_is_in_distinct' } = 0;
	    $self->{ '_is_in_array' } = 0;
            $self->{ '_is_in_filter' } = 0;
	    $self->{ '_parenthesis_filter_level' } = 0;
            $self->{ '_is_in_partition' } = 0;
            $self->{ '_is_in_over' } = 0;
	    $self->{ '_is_in_policy' } = 0;
	    $self->{ '_is_in_trigger' } = 0;
	    $self->{ '_is_in_using' } = 0;
	    $self->{ '_and_level' } = 0;
	    $self->{ '_col_count' } = 0;
	    $self->{ '_is_in_drop' } = 0;
	    $self->{ '_is_in_conversion' } = 0;
	    $self->{ '_is_in_operator' } = 0;
	    $self->{ '_is_in_explain' }  = 0;
            $self->{ '_is_in_sub_query' } = 0;
	    $self->{ '_is_in_fetch' } = 0;
            $self->{ '_is_in_aggregate' } = 0;
            $self->{ '_is_in_value' } = 0;
            $self->{ '_parenthesis_level_value' } = 0;

	    if ( $self->{ '_insert_values' } )
	    {
		if ($self->{ '_is_in_block' } == -1 and !$self->{ '_is_in_declare' } and !$self->{ '_fct_code_delimiter' })
		{
		    @{ $self->{ '_level_stack' } } = ();
		    $self->{ '_level' } = 0;
		    $self->{ 'break' } = ' ' unless ( $self->{ 'spaces' } != 0 );
		}
		elsif ($self->{ '_is_in_block' } == -1 and $self->{ '_current_sql_stmt' } eq 'INSERT' and !$self->{ '_is_in_create' } and !$self->{ '_is_in_create_function' })
		{
		    $self->_back($token, $last);
		    pop( @{ $self->{ '_level_stack' } } );
	        }
		else
		{
		    $self->{ '_level' } = pop( @{ $self->{ '_level_stack' } } ) || 0;
	        }
		$self->{ '_insert_values' } = 0;
	    }
            $self->{ '_current_sql_stmt' } = '';
            $self->{ 'break' } = "\n" unless ( $self->{ 'spaces' } != 0 );
            $self->_new_line($token,$last);
            # Add an additional newline after ; when we are not in a function
            if ($self->{ '_is_in_block' } == -1 and !$self->{ '_is_in_work' }
			    and !$self->{ '_is_in_declare' })
	    #and !$self->{ '_is_in_declare' } and !$self->{ '_fct_code_delimiter' })
	    {
		$self->{ '_new_line' } = 0;
                $self->_new_line($token,$last);
            }
            # End of statement; remove all indentation when we are not in a BEGIN/END block
            if (!$self->{ '_is_in_declare' } && $self->{ '_is_in_block' } == -1)
	    {
                @{ $self->{ '_level_stack' } } = ();
                $self->{ '_level' } = 0;
                $self->{ 'break' } = ' ' unless ( $self->{ 'spaces' } != 0 );
            }
	    elsif (not defined $self->_next_token or $self->_next_token !~ /^INSERT$/)
	    {
                if ($#{ $self->{ '_level_stack' } } == -1) {
                        $self->{ '_level' } = ($self->{ '_is_in_declare' }) ? 1 : ($self->{ '_is_in_block' }+1);
                } else {
                        $self->{ '_level' } = $self->{ '_level_stack' }[-1];
                }
            }
	    $last = $token;
        }
        elsif ($token =~ /^FOR$/i && (!$self->{ '_is_in_policy' } || $self->{ 'format_type' }))
	{
            if ($self->_next_token =~ /^(UPDATE|KEY|NO|VALUES)$/i)
	    {
                $self->_back($token, $last);
                $self->_new_line($token,$last);
            }
	    elsif ($self->_next_token =~ /^EACH$/ and $self->{ '_is_in_trigger' })
	    {
                $self->_new_line($token,$last);
	    }
            if (!$self->{ 'format_type' })
	    {
                $self->_add_token( $token );
		# cover FOR in cursor
                $self->_over($token,$last) if (uc($self->_next_token) eq 'SELECT' && !$self->{ '_is_in_policy' } && !$self->{ '_is_in_publication' });
                $last = $token;
                next;
	    }
            if ($self->_next_token =~ /^SELECT|UPDATE|DELETE|INSERT|TABLE|ALL$/i)
	    {
		# cover FOR in cursor and in policy or publication statements
		$self->_over($token,$last) if (uc($self->_next_token) eq 'SELECT' || $self->{ '_is_in_policy' } || $self->{ '_is_in_publication' });
            }
            if ($self->{ 'format_type' } && $self->{ '_is_in_policy' } || $self->{ '_is_in_publication' }) {
		$self->_new_line($token,$last);
	    }
            $self->_add_token( $token );
            $last = $token;
            next;
        }

        elsif ( $token =~ /^(?:FROM|WHERE|SET|RETURNING|HAVING|VALUES)$/i )
	{
            if (uc($token) eq 'FROM' and $self->{ '_has_order_by' } and !$self->{ '_parenthesis_level' })
	    {
                $self->_back($token, $last) if ($self->{ '_has_order_by' });
	    }

	    $self->{ 'no_break' } = 0;
            $self->{ '_col_count' } = 0;
	    # special cases for create partition statement
            if ($token =~ /^VALUES$/i && defined $last and $last =~ /^FOR|IN$/i)
	    {
		$self->_add_token( $token );
		$self->{ 'no_break' } = 1;
		$last = $token;
		next;
	    }
	    elsif ($token =~ /^FROM$/i && defined $last and uc($last) eq 'VALUES')
	    {
		$self->_add_token( $token );
		$last = $token;
		next;
	    }

	    # Case of DISTINCT FROM clause
            if ($token =~ /^FROM$/i)
	    {
		    if (uc($last) eq 'DISTINCT' || $self->{ '_is_in_fetch' } || $self->{ '_is_in_alter' } || $self->{ '_is_in_conversion' })
		    {
			$self->_add_token( $token );
			$last = $token;
			next;
		    }
	    }

            if ($token =~ /^FROM$/i)
	    {
                $self->{ '_is_in_from' }++ if (!$self->{ '_is_in_function' } && !$self->{ '_is_in_partition' });
            }

            if ($token =~ /^WHERE$/i && !$self->{ '_is_in_filter' })
	    {
                $self->_back($token, $last) if ($self->{ '_has_over_in_join' });
                $self->{ '_is_in_where' }++;
                $self->{ '_is_in_from' }-- if ($self->{ '_is_in_from' });
                $self->{ '_is_in_join' } = 0;
                $self->{ '_has_over_in_join' } = 0;
            }
	    elsif (!$self->{ '_is_in_function' })
	    {
                $self->{ '_is_in_where' }-- if ($self->{ '_is_in_where' });
            }

            if ($token =~ /^SET$/i and $self->{ '_is_in_create' })
	    {
                # Add newline before SET statement in function header
                $self->_new_line($token,$last) if (not defined $last or $last !~ /DELETE|UPDATE/i);
            }
	    elsif ($token =~ /^WHERE$/i and $self->{ '_current_sql_stmt' } eq 'DELETE')
	    {
                $self->_new_line($token,$last);
                $self->_add_token( $token );
                $self->_over($token,$last);
                $last = $token;
                $self->{ '_is_in_join' } = 0;
                $last = $token;
                next;
            }
	    elsif ($token !~ /^FROM$/i or (!$self->{ '_is_in_function' }
				    and $self->{ '_current_sql_stmt' } !~ /DELETE|REVOKE/))
	    {
                if (!$self->{ '_is_in_filter' } and ($token !~ /^SET$/i or !$self->{ '_is_in_index' }))
		{
                    $self->_back($token, $last);
		    $self->_new_line($token,$last) if (!$self->{ '_is_in_rule' });
                }
            }
	    else
	    {
                $self->_add_token( $token );
                $last = $token;
                next;
            }

            if ($token =~ /^VALUES$/i and !$self->{ '_is_in_rule' } and ($self->{ '_current_sql_stmt' } eq 'INSERT' or $last eq '('))
	    {
		$self->_over($token,$last);
		if ($self->{ '_current_sql_stmt' } eq 'INSERT' or $last eq '(') {
	            $self->{ '_insert_values' } = 1;
		    push @{ $self->{ '_level_stack' } }, $self->{ '_level' };
	        }
	    }

	    if ($token =~ /^VALUES$/i and $last eq '(')
            {
                $self->{ '_is_in_value' } = 1;
            }

	    if (uc($token) eq 'WHERE')
	    {
		$self->_add_token( $token, $last );
                $self->{ '_is_in_value' } = 0;
                $self->{ '_parenthesis_level_value' } = 0;
            }
	    else
	    {
                $self->_add_token( $token );
            }

            if ($token =~ /^VALUES$/i and $last eq '(')
	    {
                $self->_over($token,$last);
            }
            elsif ( $token =~ /^SET$/i && $self->{ '_current_sql_stmt' } eq 'UPDATE' )
	    {
                    $self->_new_line($token,$last) if (!$self->{ 'wrap_after' });
                    $self->_over($token,$last);
            }
            elsif ( !$self->{ '_is_in_over' } and !$self->{ '_is_in_filter' } and ($token !~ /^SET$/i or $self->{ '_current_sql_stmt' } eq 'UPDATE') )
	    {
                if (defined $self->_next_token and $self->_next_token ne '('
				and ($self->_next_token !~ /^(UPDATE|KEY|NO)$/i || uc($token) eq 'WHERE'))
		{
                    $self->_new_line($token,$last) if (!$self->{ 'wrap_after' });
                    $self->_over($token,$last);
                }
            }
        }

        # Add newline before INSERT and DELETE if last token was AS (prepared statement)
        elsif (defined $last and $token =~ /^INSERT|DELETE$/i and uc($last) eq 'AS')
	{
                $self->_new_line($token,$last);
                $self->_add_token( $token );
        }

        elsif ( $self->{ '_current_sql_stmt' } !~ /^(GRANT|REVOKE)$/
			and $token =~ /^(?:SELECT|PERFORM|UPDATE|DELETE)$/i
			and (!$self->{ '_is_in_policy' } || $self->{ 'format_type' })
       	)
	{
            $self->{ 'no_break' } = 0;

	    if ($token =~ /^SELECT|UPDATE|DELETE|INSERT$/i && $self->{ '_is_in_policy' } && $self->{ 'format_type' })
	    {
		$self->_over($token,$last);
	    }

            # case of ON DELETE/UPDATE clause in create table statements
	    if ($token =~ /^UPDATE|DELETE$/i && $self->{ '_is_in_create' }) {
                $self->_add_token( $token );
                $last = $token;
		next;
            }
            if ($token =~ /^UPDATE$/i and $last =~ /^(FOR|KEY)$/i)
	    {
                $self->_add_token( $token );
            }
	    elsif (!$self->{ '_is_in_policy' } && $token !~ /^DELETE$/i && (!defined $self->_next_token || $self->_next_token !~ /^DISTINCT$/i))
	    {
                $self->_new_line($token,$last);
                $self->_add_token( $token );
                $self->_new_line($token,$last) if (!$self->{ 'wrap_after' });
                $self->_over($token,$last);
            }
	    else
	    {
                $self->_add_token( $token );
            }
        }

        elsif ( $self->{ '_current_sql_stmt' } !~ /^(GRANT|REVOKE)$/
			and uc($token) eq 'INSERT' 
			and $self->{ '_is_in_policy' } && $self->{ 'format_type' })
	{
                $self->_add_token( $token );
                $self->_new_line($token,$last);
		$self->_over($token,$last);
	}
        elsif ( $token =~ /^(?:WITHIN)$/i )
	{
		$self->{ '_is_in_within' } = 1;
                $self->{ '_has_order_by' } = 1;
                $self->_add_token( $token );
                $last = $token;
		next;
	}

        elsif ( $token =~ /^(?:GROUP|ORDER|LIMIT|EXCEPTION)$/i )
	{
            $self->{ '_is_in_value' } = 0;
            $self->{ '_parenthesis_level_value' } = 0;
            if (uc($token) eq 'GROUP' and !defined $last or uc($last) eq 'EXCLUDE') {
                $self->_add_token( $token );
                $last = $token;
		next;
	    }
	    if (($self->{ '_is_in_within' } && uc($token) eq 'GROUP') || ($self->{ '_is_in_over' } && uc($token) eq 'ORDER')) {
                $self->_add_token( $token );
                $last = $token;
		next;
	    }
            if ($self->{ '_has_over_in_join' } and uc($token) eq 'GROUP')
	    {
                $self->_back($token, $last);
		$self->{ '_has_over_in_join' } = 0;
            }
            $self->{ '_is_in_join' } = 0;
            if ($token !~ /^EXCEPTION$/i) {
                $self->_back($token, $last);
            } else {
                $self->{ '_level' } = pop( @{ $self->{ '_level_stack' } } ) || 0;
            }
	    if (uc($token) ne 'EXCEPTION' or not defined $last or uc($last) ne 'RAISE')
	    {
		# Excluding CREATE/DROP GROUP
                $self->_new_line($token,$last) if (not defined $last or $last !~ /^(CREATE|DROP)$/);
            }
            $self->_add_token( $token );
            # Store current indent position to print END at the right level
            if ($token =~ /^EXCEPTION$/i)
	    {
                push @{ $self->{ '_level_stack' } }, $self->{ '_level' };
                $self->_over($token,$last);
	        $self->{ '_is_in_exception' } = 1;
            }
            $self->{ '_is_in_where' }-- if ($self->{ '_is_in_where' });
        }

        elsif ( $token =~ /^(?:BY)$/i and $last !~ /^(?:INCREMENT|OWNED|PARTITION)$/i)
	{
            $self->_add_token( $token );
	    $self->{ '_col_count' } = 0 if (defined $last && $last =~ /^(?:GROUP|ORDER)/i);
	    if (!$self->{ '_has_order_by' }) {
                $self->_new_line($token,$last) if (!$self->{ 'wrap_after' });
                $self->_over($token,$last);
	    }
        }

        elsif ( $token =~ /^(?:CASE)$/i )
	{
            $self->_add_token( $token );
            # Store current indent position to print END at the right level
            push @{ $self->{ '_level_stack' } }, $self->{ '_level' };
            # Mark next WHEN statement as first element of a case
            # to force indentation only after this element
            $self->{ '_first_when_in_case' } = 1;
            $self->{ '_is_in_case' }++;
        }

        elsif ( $token =~ /^(?:WHEN)$/i)
	{
            if (!$self->{ '_first_when_in_case' } and !$self->{'_is_in_trigger'}
			    and defined $last and uc($last) ne 'CASE'
		    	    # handle case where there is a comment between EXCEPTION and WHEN keywords
			    and !$self->{ '_is_in_exception' }
	    )
	    {
		$self->{ '_level' } = $self->{ '_level_stack' }[-1];
		$self->{ '_is_in_exception' } = 0;
	    }
            $self->_new_line($token,$last) if (not defined $last or uc($last) ne 'CASE');
            $self->_add_token( $token );
            if (!$self->{ '_is_in_case' } && !$self->{ '_is_in_trigger' }) {
                $self->_over($token,$last);
	    }
            $self->{ '_first_when_in_case' } = 0;
        }

        elsif ( $token =~ /^(?:IF|LOOP)$/i && $self->{ '_current_sql_stmt' } ne 'GRANT')
	{
            $self->_add_token( $token );
	    $self->{ 'no_break' } = 0;
            if (defined $self->_next_token and $self->_next_token !~ /^(EXISTS|;)$/i)
	    {
                $self->_new_line($token,$last) if ($token =~ /^LOOP$/i);
                $self->_over($token,$last);
                push @{ $self->{ '_level_stack' } }, $self->{ '_level' };
                if ($token =~ /^IF$/i) {
                    $self->{ '_is_in_if' } = 1;
                }
            }
        }

        elsif ($token =~ /^THEN$/i)
	{
            $self->_add_token( $token );
            $self->_new_line($token,$last);
	    $self->{ '_level' } = $self->{ '_level_stack' }[-1] if ($self->{ '_is_in_if' });
	    if ($self->{ '_is_in_case' } && defined $self->_next_token() and $self->_next_token() !~ /^(\(|RAISE)$/i) {
		$self->{ '_level' } = $self->{ '_level_stack' }[-1];
	        $self->_over($token,$last);
	    }
            $self->{ '_is_in_if' } = 0;
        }

        elsif ( $token =~ /^(?:ELSE|ELSIF)$/i )
	{
            $self->_back($token, $last);
            $self->_new_line($token,$last);
            $self->_add_token( $token );
            $self->_new_line($token,$last) if ($token !~ /^ELSIF$/i);
            $self->_over($token,$last);
        }

        elsif ( $token =~ /^(?:END)$/i )
	{
            $self->{ '_first_when_in_case' } = 0;
            if ($self->{ '_is_in_case' })
	    {
                $self->{ '_is_in_case' }--;
                $self->_back($token, $last);
		$self->{ '_level' } = pop( @{ $self->{ '_level_stack' } } ) || 0;
            }
            # When we are not in a function code block (0 is the main begin/end block of a function)
            elsif ($self->{ '_is_in_block' } == -1)
	    {
                # END is closing a create function statement so reset position to begining
                if ($self->_next_token !~ /^(IF|LOOP|CASE|INTO|FROM|END|ELSE|AND|OR|WHEN|AS|,)$/i)
		{
                    @{ $self->{ '_level_stack' } } = ();
                    $self->{ '_level' } = 0;
                    $self->{ 'break' } = ' ' unless ( $self->{ 'spaces' } != 0 );
                }
		else
		{
                    # otherwise back to last level stored at CASE keyword
                    $self->{ '_level' } = pop( @{ $self->{ '_level_stack' } } ) || 0;
                }
	    }
            # We reach the last end of the code
            elsif ($self->{ '_is_in_block' } > -1 and $self->_next_token eq ';' and !$self->{ '_is_in_exception' })
	    {
                @{ $self->{ '_level_stack' } } = ();
                $self->{ '_level' } = 0;
                $self->{ 'break' } = ' ' unless ( $self->{ 'spaces' } != 0 );
            }
            # We are in code block
	    else
	    {
                # decrease the block level if this is a END closing a BEGIN block
                if ($self->_next_token !~ /^(IF|LOOP|CASE|INTO|FROM|END|ELSE|AND|OR|WHEN|AS|,)$/i)
		{
                    $self->{ '_is_in_block' }--;
                }
                # Go back to level stored with IF/LOOP/BEGIN/EXCEPTION block
                $self->{ '_level' } = pop( @{ $self->{ '_level_stack' } } ) || 0;
                $self->_back($token, $last) if ($self->_next_token =~ /^(IF|LOOP|CASE|INTO|FROM|END|ELSE|AND|OR|WHEN|AS|,)$/i);
            }
            $self->_new_line($token,$last);
            $self->_add_token( $token );
        }

        elsif ( $token =~ /^(?:UNION|INTERSECT|EXCEPT)$/i )
	{
            $self->{ 'no_break' } = 0;
            if ($self->{ '_is_in_join' })
	    {
                $self->_back($token, $last);
                $self->{ '_is_in_join' } = 0;
            }
            $self->_back($token, $last) unless defined $last and $last eq '(';
            $self->_new_line($token,$last);
            $self->_add_token( $token );
            $self->_new_line($token,$last) if ( defined $self->_next_token
			    and $self->_next_token ne '('
			    and $self->_next_token !~ /^ALL$/i
	    );
            $self->{ '_is_in_where' }-- if ($self->{ '_is_in_where' });
            $self->{ '_is_in_from' } = 0;
        }

        elsif ( $token =~ /^(?:LEFT|RIGHT|FULL|INNER|OUTER|CROSS|NATURAL)$/i and (not defined $last or uc($last) ne 'MATCH') )
	{
            $self->{ 'no_break' } = 0;
            if (!$self->{ '_is_in_join' } and ($last and $last ne ')') )
	    {
                $self->_back($token, $last);
            }
            if ($self->{ '_has_over_in_join' })
	    {
                $self->{ '_has_over_in_join' } = 0;
                $self->_back($token, $last);
            }

            if ( $token =~ /(?:LEFT|RIGHT|FULL|CROSS|NATURAL)$/i )
	    {
                $self->_new_line($token,$last);
                $self->_over($token,$last) if ( $self->{ '_level' } == 0 );
            }
            if ( ($token =~ /(?:INNER|OUTER)$/i) && ($last !~ /(?:LEFT|RIGHT|CROSS|NATURAL|FULL)$/i) )
	    {
                $self->_new_line($token,$last);
                $self->_over($token,$last) if (!$self->{ '_is_in_join' });
            } 
            $self->_add_token( $token );
        }

        elsif ( $token =~ /^(?:JOIN)$/i and !$self->{ '_is_in_operator' })
	{
            $self->{ 'no_break' } = 0;
            if ( not defined $last or $last !~ /^(?:LEFT|RIGHT|FULL|INNER|OUTER|CROSS|NATURAL)$/i )
	    {
                $self->_new_line($token,$last);
                $self->_back($token, $last) if ($self->{ '_has_over_in_join' });
                $self->{ '_has_over_in_join' } = 0;
            }
            $self->_add_token( $token );
            $self->{ '_is_in_join' } = 1;
        }

        elsif ( $token =~ /^(?:AND|OR)$/i )
	{
            # Try to detect AND in BETWEEN clause to prevent newline insert
            if (uc($token) eq 'AND' and ($self->_next_token() =~ /^\d+$/ || (defined $last && $last =~ /^(PRECEDING|FOLLOWING|ROW)$/i)))
	    {
                $self->_add_token( $token );
                $last = $token;
                next;
            }
            $self->{ 'no_break' } = 0;
            if ($self->{ '_is_in_join' })
	    {
                $self->_over($token,$last);
                $self->{ '_has_over_in_join' } = 1;
            }
            $self->{ '_is_in_join' } = 0;
            if ( !$self->{ '_is_in_if' } and !$self->{ '_is_in_index' }
			    and (!$last or $last !~ /^(?:CREATE)$/i) )
	    {
                $self->_new_line($token,$last);
                if (!$self->{'_and_level'} and (!$self->{ '_level' } || $self->{ '_is_in_alter' })) {
                        $self->_over($token,$last);
                } elsif ($self->{'_and_level'} and !$self->{ '_level' } and uc($token) eq 'OR') {
                        $self->_over($token,$last);
                } elsif ($#{$self->{ '_level_stack' }} >= 0 and $self->{ '_level' } == $self->{ '_level_stack' }[-1]) {
                        $self->_over($token,$last);
                }
            }
            $self->_add_token( $token );
	    $self->{'_and_level'}++;
        }

        elsif ( $token =~ /^\/\*.*\*\/$/s )
	{
            if ( !$self->{ 'no_comments' } )
	    {
                $token =~ s/\n[\s\t]+\*/\n\*/gs;
		$self->_new_line($token,$last), $self->_add_token('') if (defined $last and $last eq ';');
                $self->_new_line($token,$last);
                $self->_add_token( $token );
                $self->{ 'break' } = "\n" unless ( $self->{ 'spaces' } != 0 );
                $self->_new_line($token,$last);
                $self->{ 'break' } = " " unless ( $self->{ 'spaces' } != 0 );
            }
        }

        elsif ($token =~ /^USING$/i and (!$self->{ '_is_in_policy' } || $self->{ 'format_type' }))
	{
	    $self->{ '_is_in_using' } = 1;
            if (!$self->{ '_is_in_from' })
	    {
		$self->_over($token,$last) if ($self->{ '_is_in_operator' });
                $self->_new_line($token,$last) if (uc($last) ne 'EXCLUDE');
            }
	    else
	    {
                # USING from join clause disable line break
		#$self->{ 'no_break' } = 1;
                $self->{ '_is_in_function' }++;
            }
            $self->_add_token($token);
        }

	elsif ($token =~ /^EXCLUDE$/i)
	{
	    if ($last !~ /^(FOLLOWING|ADD)$/i or $self->_next_token !~ /^USING$/i) {
                $self->_new_line($token,$last) if ($last !~ /^(FOLLOWING|ADD)$/i);
	    }
            $self->_add_token( $token );
	    $self->{ '_is_in_using' } = 1;
        }

        elsif ($token =~ /^\\\S/)
	{
	    # treat everything starting with a \ and at least one character as psql meta command. 
            $self->_add_token( $token );
            $self->_new_line($token,$last);
        }

        elsif ($token =~ /^ADD|DROP$/i && ($self->{ '_current_sql_stmt' } eq 'SEQUENCE'
			|| $self->{ '_current_sql_stmt' } eq 'ALTER'))
	{
	    if ($self->_next_token !~ /^NOT|NULL|DEFAULT$/i and (not defined $last or !$self->{ '_is_in_alter' } or $last ne '(')) {
                $self->_new_line($token,$last);
                if ($self->{ '_is_in_alter' } < 2) {
                    $self->_over($token,$last);
	        }
	    }
            $self->_add_token($token, $last);
	    $self->{ '_is_in_alter' }++ if ($self->{ '_is_in_alter' } == 1);
        }

        elsif ($token =~ /^INCREMENT$/i && $self->{ '_current_sql_stmt' } eq 'SEQUENCE')
	{
            $self->_new_line($token,$last);
            $self->_add_token($token);
        }

        elsif ($token =~ /^NO$/i and $self->_next_token =~ /^(MINVALUE|MAXVALUE)$/i)
	{
            $self->_new_line($token,$last);
            $self->_add_token($token);
        }

        elsif ($last !~ /^(\(|NO)$/i and $token =~ /^(MINVALUE|MAXVALUE)$/i)
	{
            $self->_new_line($token,$last);
            $self->_add_token($token);
        }

        elsif ($token =~ /^CACHE$/i)
	{
            $self->_new_line($token,$last);
            $self->_add_token($token);
        }

        else
	{
	     if ($self->{ '_fct_code_delimiter' } and $self->{ '_fct_code_delimiter' } =~ /^'.*'$/) {
	 	$self->{ '_fct_code_delimiter' } = "";
	     }
	     # special case with comment
	     if ($token =~ /(?:\s*--)[\ \t\S]*/s)
	     {
		 $token =~ s/^(\s*)(--.*)/$2/s;
		 my $start = $1 || '';
		 if ($start =~ /\n/s) {
                     $self->_new_line($token,$last), $self->_add_token('') if (defined $last and $last eq ';' and $self->{ 'content' } !~ /\n$/s);
		     $self->_new_line($token,$last);
		 }
		 $token =~ s/\s+$//s;
		 $token =~ s/^\s+//s;
                 $self->_add_token( $token );
                 $self->_new_line($token,$last) if ($start || $self->{ 'content' } !~ /\n/s);
		 # Add extra newline after the last comment if we are not in a block or a statement
		 if (defined $self->_next_token and $self->_next_token !~ /^\s*--/) {
                     $self->{ 'content' } .= "\n" if ($self->{ '_is_in_block' } == -1
				     and !$self->{ '_is_in_declare' } and !$self->{ '_fct_code_delimiter' }
		                     and !$self->{ '_current_sql_stmt' }
			     	     and defined $last and $self->_is_comment($last)
		     		);
		 }
                 $last = $token;
		 next;
	     }

             if ($last =~ /^(?:SEQUENCE)$/i and $self->_next_token !~ /^(OWNED|;)$/i)
	     {
                 $self->_add_token( $token );
                 $self->_new_line($token,$last);
                 $self->_over($token,$last);
             }
             else
	     {
                 if (defined $last && $last eq ')' && (!defined $self->_next_token || $self->_next_token ne ';'))
		 {
                     if (!$self->{ '_parenthesis_level' } && $self->{ '_is_in_from' })
		     {
                         $self->{ '_level' } = pop(@{ $self->{ '_level_parenthesis' } }) || 1;
                     }
                 }
                 $self->_add_token( $token, $last );
                 if (defined $last && uc($last) eq 'LANGUAGE' && (!defined $self->_next_token || $self->_next_token ne ';'))
                 {
                     $self->_new_line($token,$last);
                 }
            }
        }

        $last = $token;
        $pos++;
    }

    $self->_new_line();

    return;
}

=head2 _add_token

Add a token to the beautified string.

Code lifted from SQL::Beautify

=cut

sub _add_token {
    my ( $self, $token, $last_token ) = @_;

    if ($DEBUG) {
        my ($package, $filename, $line) = caller;
        print STDERR "DEBUG_ADD: line: $line => last=", ($last_token||''), ", token=$token\n";
    }

    if ( $self->{ 'wrap' } ) {
        my $wrap;
        if ( $self->_is_keyword( $token ) ) {
            $wrap = $self->{ 'wrap' }->{ 'keywords' };
        }
        elsif ( $self->_is_constant( $token ) ) {
            $wrap = $self->{ 'wrap' }->{ 'constants' };
        }

        if ( $wrap ) {
            $token = $wrap->[ 0 ] . $token . $wrap->[ 1 ];
        }
    }

    my $last_is_dot = defined( $last_token ) && $last_token eq '.';

    my $sp = $self->_indent;

    if ( !$self->_is_punctuation( $token ) and !$last_is_dot)
    {
        if ( (!defined($last_token) || $last_token ne '(') && $token ne ')' && $token !~ /^::/ ) {
            $self->{ 'content' } .= $sp if ($token ne ')'
                                            && defined($last_token)
                                            && $last_token ne '::' 
                                            && $last_token ne '[' 
					    && ($token ne '(' || !$self->_is_function( $last_token ) || $self->{ '_is_in_type' })
                );
            $self->{ 'content' } .= $sp if (!defined($last_token) && $token);
        } elsif ( defined $last_token && $last_token eq '(' && $token ne ')' && $token !~ /^::/ && !$self->{'wrap_after'} && $self->{ '_is_in_with' } == 1) {
		$self->{ 'content' } .= $sp;
        } elsif ( $self->{ '_is_in_create' } == 2 && defined($last_token)) {
             $self->{ 'content' } .= $sp if ($last_token ne '::' and !$self->{ '_is_in_partition' }
		     				and !$self->{ '_is_in_policy' }
					        and !$self->{ '_is_in_trigger' }
						and !$self->{ '_is_in_aggregate' }
						and ($last_token ne '(' || !$self->{ '_is_in_index' }));
        } elsif (defined $last_token and (!$self->{ '_is_in_operator' } or !$self->{ '_is_in_alter' })) {
            $self->{ 'content' } .= $sp if ($last_token eq '(' && ($self->{ '_is_in_type' } or ($self->{ '_is_in_operator' } and !$self->_is_type($token))));
        } elsif ($token eq ')' and $self->{ '_is_in_block' } >= 0 && $self->{ '_is_in_create' }) {
                $self->{ 'content' } .= $sp;
        }
        if ($self->_is_comment($token)) {
            my @lines = split(/\n/, $token);
            for (my $i = 1; $i <= $#lines; $i++) {
                if ($lines[$i] =~ /^\s*\*/) {
                    $lines[$i] =~ s/^\s*\*/$sp */;
                } elsif ($lines[$i] =~ /^\s+[^\*]/) {
                    $lines[$i] =~ s/^\s+/$sp /;
                }
            }
            $token = join("\n", @lines);
        } else {
            $token =~ s/\n/\n$sp/gs;
        }
    }

    my $next_token = $self->_next_token || '';

    # lowercase/uppercase keywords taking care of function with same name
    if ($self->_is_keyword( $token, $next_token, $last_token ) && (!$self->_is_function( $token ) || $next_token ne '(')) {
        $token = lc( $token )            if ( $self->{ 'uc_keywords' } == 1 );
        $token = uc( $token )            if ( $self->{ 'uc_keywords' } == 2 );
        $token = ucfirst( lc( $token ) ) if ( $self->{ 'uc_keywords' } == 3 );
    }
    else
    {

        # lowercase/uppercase known functions or words followed by an open parenthesis
        # if the token is not a keyword, an open parenthesis or a comment
        my $fct = $self->_is_function( $token ) || '';
        if (($fct && $next_token eq '(')
		    || (!$self->_is_keyword( $token ) && !$next_token eq '('
			    && $token ne '(' && !$self->_is_comment( $token )) ) {
            $token =~ s/$fct/\L$fct\E/i if ( $self->{ 'uc_functions' } == 1 );
            $token =~ s/$fct/\U$fct\E/i if ( $self->{ 'uc_functions' } == 2 );
            $fct = ucfirst( lc( $fct ) );
            $token =~ s/$fct/$fct/i if ( $self->{ 'uc_functions' } == 3 );
        }
    }

    # Add formatting for HTML output
    if ( $self->{ 'colorize' } && $self->{ 'format' } eq 'html' ) {
        $token = $self->highlight_code($token, $last_token, $next_token);
    }

    $self->{ 'content' } .= $token;

    # This can't be the beginning of a new line anymore.
    $self->{ '_new_line' } = 0;
}

=head2 _over

Increase the indentation level.

Code lifted from SQL::Beautify

=cut

sub _over {
    my ( $self, $token, $last ) = @_;

    if ($DEBUG) {
        my ($package, $filename, $line) = caller;
        print STDERR "DEBUG_OVER: line: $line => last=$last, token=$token\n";
    }

    ++$self->{ '_level' };
}

=head2 _back

Decrease the indentation level.

Code lifted from SQL::Beautify

=cut

sub _back {
    my ( $self, $token, $last ) = @_;

    if ($DEBUG) {
        my ($package, $filename, $line) = caller;
        print STDERR "DEBUG_BACK: line: $line => last=$last, token=$token\n";
    }
    --$self->{ '_level' } if ( $self->{ '_level' } > 0 );
}

=head2 _indent

Return a string of spaces according to the current indentation level and the
spaces setting for indenting.

Code lifted from SQL::Beautify

=cut

sub _indent {
    my ( $self ) = @_;

    if ( $self->{ '_new_line' } ) {
        return $self->{ 'space' } x ( $self->{ 'spaces' } * ( $self->{ '_level' } // 0 ) );
    }
    else {
        return $self->{ 'space' };
    }
}

=head2 _new_line

Add a line break, but make sure there are no empty lines.

Code lifted from SQL::Beautify

=cut

sub _new_line {
    my ( $self, $token, $last ) = @_;

    if ($DEBUG and defined $token) {
        my ($package, $filename, $line) = caller;
        print STDERR "DEBUG_NL: line: $line => last=", ($last||''), ", token=$token\n";
    }

    $self->{ 'content' } .= $self->{ 'break' } unless ( $self->{ '_new_line' } );
    $self->{ '_new_line' } = 1;
}

=head2 _next_token

Have a look at the token that's coming up next.

Code lifted from SQL::Beautify

=cut

sub _next_token {
    my ( $self ) = @_;

    return @{ $self->{ '_tokens' } } ? $self->{ '_tokens' }->[ 0 ] : undef;
}

=head2 _token

Get the next token, removing it from the list of remaining tokens.

Code lifted from SQL::Beautify

=cut

sub _token {
    my ( $self ) = @_;

    return shift @{ $self->{ '_tokens' } };
}

=head2 _is_keyword

Check if a token is a known SQL keyword.

Code lifted from SQL::Beautify

=cut

sub _is_keyword {
    my ( $self, $token, $next_token, $last_token ) = @_;

    # Fix some false positive
    if (defined $next_token) {
        return 0 if (uc($token) eq 'EVENT' and uc($next_token) ne 'TRIGGER');
    }

    return ~~ grep { $_ eq uc( $token ) } @{ $self->{ 'keywords' } };
}

=head2 _is_type

Check if a token is a known SQL type

=cut

sub _is_type {
    my ( $self, $token ) = @_;

    return ~~ grep { $_ eq uc( $token ) } @{ $self->{ 'types' } };
}


sub _is_sql_keyword {
    my ( $self, $token ) = @_;

    return ~~ grep { $_ eq uc( $token ) } @{ $self->{ 'sql_keywords' } };
}


=head2 _is_comment

Check if a token is a SQL or C style comment

=cut


sub _is_comment {
    my ( $self, $token ) = @_;

    return 1 if ( $token =~ m#^((?:--)[\ \t\S]*|/\*[\ \t\r\n\S]*?\*/)$#s );

    return 0;
}

=head2 _is_function

Check if a token is a known SQL function.

Code lifted from SQL::Beautify and rewritten to check one long regexp instead of a lot of small ones.

=cut

sub _is_function {
    my ( $self, $token ) = @_;

    if ( $token =~ $self->{ 'functions_re' } ) {
        return $1;
    } else {
        return undef;
    }
}

=head2 add_keywords

Add new keywords to highlight.

Code lifted from SQL::Beautify

=cut

sub add_keywords {
    my $self = shift;

    for my $keyword ( @_ ) {
        push @{ $self->{ 'keywords' } }, ref( $keyword ) ? @{ $keyword } : $keyword;
    }
}

=head2 _re_from_list

Create compiled regexp from prefix, suffix and and a list of values to match.

=cut

sub _re_from_list {
    my $prefix = shift;
    my $suffix = shift;
    my (@joined_list, $ret_re);

    for my $list_item ( @_ ) {
        push @joined_list, ref( $list_item ) ? @{ $list_item } : $list_item;
    }

    $ret_re = "$prefix(" . join('|', @joined_list) . ")$suffix";

    return qr/$ret_re/i;
}

=head2 _refresh_functions_re

Refresh compiled regexp for functions.

=cut

sub _refresh_functions_re {
    my $self = shift;
    $self->{ 'functions_re' } = _re_from_list( '\b[\.]*', '$', @{ $self->{ 'functions' } });
}

=head2 add_functions

Add new functions to highlight.

Code lifted from SQL::Beautify

=cut

sub add_functions {
    my $self = shift;

    for my $function ( @_ ) {
        push @{ $self->{ 'functions' } }, ref( $function ) ? @{ $function } : $function;
    }

    $self->_refresh_functions_re();
}

=head2 add_rule

Add new rules.

Code lifted from SQL::Beautify

=cut

sub add_rule {
    my ( $self, $format, $token ) = @_;

    my $rules = $self->{ 'rules' }  ||= {};
    my $group = $rules->{ $format } ||= [];

    push @{ $group }, ref( $token ) ? @{ $token } : $token;
}

=head2 _get_rule

Find custom rule for a token.

Code lifted from SQL::Beautify

=cut

sub _get_rule {
    my ( $self, $token ) = @_;

    values %{ $self->{ 'rules' } };    # Reset iterator.

    while ( my ( $rule, $list ) = each %{ $self->{ 'rules' } } ) {
        return $rule if ( grep { uc( $token ) eq uc( $_ ) } @$list );
    }

    return;
}

=head2 _process_rule

Applies defined rule.

Code lifted from SQL::Beautify

=cut

sub _process_rule {
    my ( $self, $rule, $token ) = @_;

    my $format = {
        break => sub { $self->_new_line() },
        over  => sub { $self->_over() },
        back  => sub { $self->_back() },
        token => sub { $self->_add_token( $token ) },
        push  => sub { push @{ $self->{ '_level_stack' } }, $self->{ '_level' } },
        pop   => sub { $self->{ '_level' } = pop( @{ $self->{ '_level_stack' } } ) || 0 },
        reset => sub { $self->{ '_level' } = 0; @{ $self->{ '_level_stack' } } = (); },
    };

    for ( split /-/, lc $rule ) {
        &{ $format->{ $_ } } if ( $format->{ $_ } );
    }
}

=head2 _is_constant

Check if a token is a constant.

Code lifted from SQL::Beautify

=cut

sub _is_constant {
    my ( $self, $token ) = @_;

    return ( $token =~ /^\d+$/ or $token =~ /^(['"`]).*\1$/ );
}

=head2 _is_punctuation

Check if a token is punctuation.

Code lifted from SQL::Beautify

=cut

sub _is_punctuation {
    my ( $self, $token ) = @_;
    if  ($self->{ 'comma' } eq 'start' and $token eq ',') {
    return 0;
    }
    return ( $token =~ /^[,;.\[\]]$/ );
}

=head2 _generate_anonymized_string

Simply generate a random string, thanks to Perlmonks.

Returns original in certain cases which don't require anonymization, like
timestamps, or intervals.

=cut

sub _generate_anonymized_string {
    my $self = shift;
    my ( $before, $original, $after ) = @_;

    # Prevent dates from being anonymized
    return $original if $original =~ m{\A\d\d\d\d[/:-]\d\d[/:-]\d\d\z};
    return $original if $original =~ m{\A\d\d[/:-]\d\d[/:-]\d\d\d\d\z};

    # Prevent dates format like DD/MM/YYYY HH24:MI:SS from being anonymized
    return $original if $original =~ m{
        \A
        (?:FM|FX|TM)?
        (?:
            HH | HH12 | HH24
            | MI
            | SS
            | MS
            | US
            | SSSS
            | AM | A\.M\. | am | a\.m\.
            | PM | P\.M\. | pm | p\.m\.
            | Y,YYY | YYYY | YYY | YY | Y
            | IYYY | IYY | IY | I
            | BC | B\.C\. | bc | b\.c\.
            | AD | A\.D\. | ad | a\.d\.
            | MONTH | Month | month | MON | Mon | mon | MM
            | DAY | Day | day | DY | Dy | dy | DDD | DD | D
            | W | WW | IW
            | CC
            | J
            | Q
            | RM | rm
            | TZ | tz
            | [\s/:-]
        )+
        (?:TH|th|SP)?
        \z
    };

    # Prevent interval from being anonymized

    return $original if ($before && ($before =~ /interval/i));
    return $original if ($after && ($after =~ /^\)*::interval/i));

    # Shortcut
    my $cache = $self->{ '_anonymization_cache' };

    # Range of characters to use in anonymized strings
    my @chars = ( 'A' .. 'Z', 0 .. 9, 'a' .. 'z', '-', '_', '.' );

    unless ( $cache->{ $original } ) {

        # Actual anonymized version generation
        $cache->{ $original } = join( '', map { $chars[ rand @chars ] } 1 .. 10 );
    }

    return $cache->{ $original };
}

=head2 anonymize

Anonymize litteral in SQL queries by replacing parameters with fake values

=cut

sub anonymize {
    my $self  = shift;
    my $query = $self->query;

    return if ( !$query );

    # Variable to hold anonymized versions, so we can provide the same value
    # for the same input, within single query.
    $self->{ '_anonymization_cache' } = {};

    # Remove comments
    $query =~ s/\/\*(.*?)\*\///gs;

    # Clean query
    $query =~ s/\\'//gs;
    $query =~ s/('')+/\$EMPTYSTRING\$/gs;

    # Anonymize each values
    $query =~ s{
        ([^\s\']+[\s\(]*)       # before
        '([^']*)'               # original
        ([\)]*::\w+)?           # after
    }{$1 . "'" . $self->_generate_anonymized_string($1, $2, $3) . "'" . ($3||'')}xeg;

    $query =~ s/\$EMPTYSTRING\$/''/gs;

    $self->query( $query );
}

=head2 set_defaults

Sets defaults for newly created objects.

Currently defined defaults:

=over

=item spaces => 4

=item space => ' '

=item break => "\n"

=item uc_keywords => 0

=item uc_functions => 0

=item no_comments => 0

=item placeholder => ''

=item separator => ''

=item comma => 'end'

=item format => 'text'

=item colorize => 1

=item format_type => 0

=item wrap_limit => 0

=item wrap_after => 0

=back

=cut

sub set_defaults {
    my $self = shift;
    $self->set_dicts();

    # Set some defaults.
    $self->{ 'query' }        = '';
    $self->{ 'spaces' }       = 4;
    $self->{ 'space' }        = ' ';
    $self->{ 'break' }        = "\n";
    $self->{ 'wrap' }         = {};
    $self->{ 'rules' }        = {};
    $self->{ 'uc_keywords' }  = 0;
    $self->{ 'uc_functions' } = 0;
    $self->{ 'no_comments' }  = 0;
    $self->{ 'placeholder' }  = '';
    $self->{ 'keywords' }     = $self->{ 'dict' }->{ 'pg_keywords' };
    $self->{ 'types' }        = $self->{ 'dict' }->{ 'pg_types' };
    $self->{ 'functions' }    = ();
    push(@{ $self->{ 'functions' } }, keys %{ $self->{ 'dict' }->{ 'pg_functions' } });
    $self->_refresh_functions_re();
    $self->{ 'separator' }    = '';
    $self->{ 'comma' }        = 'end';
    $self->{ 'format' }       = 'text';
    $self->{ 'colorize' }     = 1;
    $self->{ 'format_type' }  = 0;
    $self->{ 'wrap_limit' }   = 0;
    $self->{ 'wrap_after' }   = 0;

    return;
}

=head2 format

Set output format - possible values: 'text' and 'html'

Default is text output. Returns 0 in case or wrong format and use default.

=cut

sub format {
    my $self  = shift;
    my $format  = shift;

    if ( grep(/^$format$/i, 'text', 'html') ) {
        $self->{ 'format' } = lc($format);
    return 1;
    }
    return 0;
}

=head2 set_dicts

Sets various dictionaries (lists of keywords, functions, symbols, and the like)

This was moved to separate function, so it can be put at the very end of module
so it will be easier to read the rest of the code.

=cut

sub set_dicts {
    my $self = shift;

    # First load it all as "my" variables, to make it simpler to modify/map/grep/add
    # Afterwards, when everything is ready, put it in $self->{'dict'}->{...}

    my @pg_keywords = map { uc } qw( 
        ADD AFTER AGGREGATE ALL ALTER ANALYSE ANALYZE AND ANY ARRAY AS ASC ASYMMETRIC AUTHORIZATION ATTACH AUTO_INCREMENT
        BACKWARD BEFORE BEGIN BERNOULLI BETWEEN BINARY BOTH BY CACHE CASCADE CASE CAST CHECK CHECKPOINT CLOSE CLUSTER
	COLLATE COLLATION COLUMN COMMENT COMMIT COMMITTED CONCURRENTLY CONFLICT CONSTRAINT CONSTRAINT CONTINUE COPY
	COST COSTS CREATE CROSS CUBE CURRENT CURRENT_DATE CURRENT_ROLE CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER CURSOR
	CYCLE DATABASE DEALLOCATE DECLARE DEFAULT DEFERRABLE DEFERRED DEFINER DELETE DELIMITER DESC DETACH EVENT DISTINCT
	DO DOMAIN DROP EACH ELSE ENCODING END EXCEPT EXCLUDE EXCLUDING EXECUTE EXISTS EXPLAIN EXTENSION FALSE FETCH FILTER
	FIRST FOLLOWING FOR FOREIGN FORWARD FREEZE FROM FULL FUNCTION GENERATED GRANT GROUP GROUPING HAVING HASHES HASH
	IDENTITY IF ILIKE IMMUTABLE IN INCLUDING INCREMENT INDEX INHERITS INITIALLY INNER INOUT INSERT INSTEAD
	INTERSECT INTO INVOKER IS ISNULL ISOLATION JOIN KEY LANGUAGE LAST LATERAL LC_COLLATE LC_CTYPE LEADING
	LEAKPROOF LEFT LEFTARG LIKE LIMIT LIST LISTEN LOAD LOCALTIME LOCALTIMESTAMP LOCATION LOCK LOCKED LOGGED LOGIN
	LOOP MAPPING MATCH MAXVALUE MERGES MINVALUE MODULUS MOVE NATURAL NEXT ORDINALITY
        NO NOCREATEDB NOCREATEROLE NOSUPERUSER NOT NOTIFY NOTNULL NOWAIT NULL OFF OF OIDS ON ONLY OPEN OPERATOR OR ORDER
        OUTER OVER OVERLAPS OWNER PARTITION PASSWORD PERFORM PLACING POLICY PRECEDING PREPARE PRIMARY PROCEDURE RANGE
        REASSIGN RECURSIVE REFERENCES REINDEX REMAINDER RENAME REPEATABLE REPLACE REPLICA RESET RESTART RESTRICT RETURN RETURNING
        RETURNS RETURNS REVOKE RIGHT RIGHTARG ROLE ROLLBACK ROLLUP ROWS ROW RULE SAVEPOINT SCHEMA SCROLL SECURITY SELECT SEQUENCE
        SEQUENCE SERIALIZABLE SERVER SESSION_USER SET SETOF SETS SHOW SIMILAR SKIP SNAPSHOT SOME STABLE START STRICT
        SYMMETRIC SYSTEM TABLE TABLESAMPLE TABLESPACE TEMPLATE TEMPORARY THEN TO TRAILING TRANSACTION TRIGGER TRUE
        TRUNCATE TYPE UNBOUNDED UNCOMMITTED UNION UNIQUE UNLISTEN UNLOCK UNLOGGED UPDATE USER USING VACUUM VALUES
        VARIADIC VERBOSE VIEW VOLATILE WHEN WHERE WINDOW WITH WITHIN WORK XOR ZEROFILL
	CALL GROUPS INCLUDE OTHERS PROCEDURES ROUTINE ROUTINES TIES READ_ONLY SHAREABLE READ_WRITE
        BASETYPE SFUNC STYPE SFUNC1 STYPE1 SSPACE FINALFUNC FINALFUNC_EXTRA FINALFUNC_MODIFY COMBINEFUNC SERIALFUNC DESERIALFUNC
       	INITCOND MSFUNC MINVFUNC MSTYPE MSSPACE MFINALFUNC MFINALFUNC_EXTRA MFINALFUNC_MODIFY MINITCOND SORTOP
        );

    my @pg_types = qw(
        BIGINT BIGSERIAL BIT BOOLEAN BOX BYTEA CHARACTER CIDR CIRCLE DATE DOUBLE INET INT INTEGER INTERVAL JSON
        JSONB LINE LSEG MACADDR MACADDR8 MONEY NUMERIC PATH PG_LSN POINT POLYGON REAL SMALLINT SMALLSERIAL
       	SERIAL TEXT TIME TIMESTAMP TSQUERY TSVECTOR TXID_SNAPSHOT UUID XML INT2 INT4 INT8 VARYING
	);

    my @sql_keywords = map { uc } qw(
        ABORT ABSOLUTE ACCESS ACTION ADMIN ALSO ALWAYS ASSERTION ASSIGNMENT AT ATTRIBUTE BIGINT BOOLEAN
        CALLED CASCADED CATALOG CHAIN CHANGE CHARACTER CHARACTERISTICS COLUMNS COMMENTS CONFIGURATION
        CONNECTION CONSTRAINTS CONTENT CONVERSION CSV CURRENT DATA DATABASES DAY DEC DECIMAL DEFAULTS DELAYED
        DELIMITERS DESCRIBE DICTIONARY DISABLE DISCARD DOCUMENT DOUBLE ENABLE ENCLOSED ENCRYPTED ENUM ESCAPE ESCAPED
        EXCLUSIVE EXTERNAL FIELD FIELDS FLOAT FLUSH FOLLOWING FORCE FUNCTIONS GLOBAL GRANTED GREATEST HANDLER
        HEADER HOLD HOUR IDENTIFIED IGNORE IMMEDIATE IMPLICIT INDEXES INFILE INHERIT INLINE INPUT INSENSITIVE
        INT INTEGER KEYS KILL LABEL LARGE LEAST LEVEL LINES LOCAL LOW_PRIORITY MATCH MINUTE MODE MODIFY MONTH NAMES
        NATIONAL NCHAR NONE NOTHING NULLIF NULLS OBJECT OFF OPERATOR OPTIMIZE OPTION OPTIONALLY OPTIONS OUT OUTFILE
        OWNED PARSER PARTIAL PASSING PLANS PRECISION PREPARED PRESERVE PRIOR PRIVILEGES PROCEDURAL QUOTE READ
        REAL RECHECK REF REGEXP RELATIVE RELEASE RLIKE ROW SEARCH SECOND SEQUENCES SESSION SHARE SIMPLE
        SMALLINT SONAME STANDALONE STATEMENT STATISTICS STATUS STORAGE STRAIGHT_JOIN SYSID TABLES TEMP TERMINATED
        TREAT TRUSTED TYPES UNENCRYPTED UNKNOWN UNSIGNED UNTIL USE VALID VALIDATE VALIDATOR VALUE VARIABLES VARYING
        WHITESPACE WITHOUT WORK WRAPPER WRITE XMLATTRIBUTES YEAR YES ZONE
        );

    my @redshift_keywords =  map { uc } qw(
        AES128 AES256 ALLOWOVERWRITE BACKUP BLANKSASNULL BYTEDICT BZIP2 CREDENTIALS CURRENT_USER_ID DEFLATE DEFRAG
        DELTA DELTA32K DISABLE DISTKEY EMPTYASNULL ENABLE ENCODE ENCRYPT ENCRYPTION EXPLICIT GLOBALDICT256
        GLOBALDICT64K GZIP INTERLEAVED LUN LUNS LZO LZOP MINUS MOSTLY13 MOSTLY32 MOSTLY8 NEW OFFLINE OFFSET OID OLD
        PARALLEL PERCENT PERMISSIONS RAW READRATIO RECOVER REJECTLOG RESORT RESPECT RESTORE SORTKEY SYSDATE TAG TDES
        TEXT255 TEXT32K TIMESTAMP TOP TRUNCATECOLUMNS WALLET
        );

    for my $k ( @pg_keywords ) {
        next if grep { $k eq $_ } @sql_keywords;
        push @sql_keywords, $k;
    }

    for my $k ( @redshift_keywords ) {
        next if grep { $k eq $_ } @sql_keywords;
        push @sql_keywords, $k;
    }

    my @pg_functions = map { lc } qw(
        ascii age bit_length btrim cardinality cast char_length character_length coalesce
	convert chr current_date current_time current_timestamp count decode date_part date_trunc
	encode extract get_byte get_bit initcap isfinite interval justify_hours justify_days
        lower length lpad ltrim localtime localtimestamp md5 now octet_length overlay position pg_client_encoding
        quote_ident quote_literal repeat replace rpad rtrim substring split_part strpos substr set_byte set_bit
        trim to_ascii to_hex translate to_char to_date to_timestamp to_number timeofday upper
        abbrev abs abstime abstimeeq abstimege abstimegt abstimein abstimele
        abstimelt abstimene abstimeout abstimerecv abstimesend aclcontains acldefault
        aclexplode aclinsert aclitemeq aclitemin aclitemout aclremove acos
        any_in any_out anyarray_in anyarray_out anyarray_recv anyarray_send anyelement_in
        anyelement_out anyenum_in anyenum_out anynonarray_in anynonarray_out anyrange_in anyrange_out
        anytextcat area areajoinsel areasel armor array_agg array_agg_finalfn
        array_agg_transfn array_append array_cat array_dims array_eq array_fill array_ge array_positions
        array_gt array_in array_larger array_le array_length array_lower array_lt array_position
        array_ndims array_ne array_out array_prepend array_recv array_remove array_replace array_send array_smaller
        array_to_json array_to_string array_typanalyze array_upper arraycontained arraycontains arraycontjoinsel
        arraycontsel arrayoverlap ascii_to_mic ascii_to_utf8 asin atan atan2
        avg big5_to_euc_tw big5_to_mic big5_to_utf8 bit bit_and bit_in
        bit_or bit_out bit_recv bit_send bitand bitcat bitcmp
        biteq bitge bitgt bitle bitlt bitne bitnot
        bitor bitshiftleft bitshiftright bittypmodin bittypmodout bitxor bool
        bool_and bool_or booland_statefunc booleq boolge boolgt boolin
        boolle boollt boolne boolor_statefunc boolout boolrecv boolsend
        box box_above box_above_eq box_add box_below box_below_eq box_center
        box_contain box_contain_pt box_contained box_distance box_div box_eq box_ge
        box_gt box_in box_intersect box_le box_left box_lt box_mul
        box_out box_overabove box_overbelow box_overlap box_overleft box_overright box_recv
        box_right box_same box_send box_sub bpchar bpchar_larger bpchar_pattern_ge
        bpchar_pattern_gt bpchar_pattern_le bpchar_pattern_lt bpchar_smaller bpcharcmp bpchareq bpcharge
        bpchargt bpchariclike bpcharicnlike bpcharicregexeq bpcharicregexne bpcharin bpcharle
        bpcharlike bpcharlt bpcharne bpcharnlike bpcharout bpcharrecv bpcharregexeq
        bpcharregexne bpcharsend bpchartypmodin bpchartypmodout broadcast btabstimecmp btarraycmp
        btbeginscan btboolcmp btbpchar_pattern_cmp btbuild btbuildempty btbulkdelete btcanreturn
        btcharcmp btcostestimate btendscan btfloat48cmp btfloat4cmp btfloat4sortsupport btfloat84cmp
        btfloat8cmp btfloat8sortsupport btgetbitmap btgettuple btinsert btint24cmp btint28cmp
        btint2cmp btint2sortsupport btint42cmp btint48cmp btint4cmp btint4sortsupport btint82cmp
        btint84cmp btint8cmp btint8sortsupport btmarkpos btnamecmp btnamesortsupport btoidcmp
        btoidsortsupport btoidvectorcmp btoptions btrecordcmp btreltimecmp btrescan btrestrpos
        bttext_pattern_cmp bttextcmp bttidcmp bttintervalcmp btvacuumcleanup bytea_string_agg_finalfn
	bytea_string_agg_transfn byteacat byteacmp byteaeq byteage byteagt byteain byteale
        bytealike bytealt byteane byteanlike byteaout bytearecv byteasend
        cash_cmp cash_div_cash cash_div_flt4 cash_div_flt8 cash_div_int2 cash_div_int4 cash_eq
        cash_ge cash_gt cash_in cash_le cash_lt cash_mi cash_mul_flt4
        cash_mul_flt8 cash_mul_int2 cash_mul_int4 cash_ne cash_out cash_pl cash_recv
        cash_send cash_words cashlarger cashsmaller cbrt ceil ceiling
        center char chareq charge chargt charin charle
        charlt charne charout charrecv charsend cideq cidin
        cidout cidr cidr_in cidr_out cidr_recv cidr_send cidrecv
        cidsend circle circle_above circle_add_pt circle_below circle_center circle_contain
        circle_contain_pt circle_contained circle_distance circle_div_pt circle_eq circle_ge circle_gt
        circle_in circle_le circle_left circle_lt circle_mul_pt circle_ne circle_out
        circle_overabove circle_overbelow circle_overlap circle_overleft circle_overright circle_recv circle_right
        circle_same circle_send circle_sub_pt clock_timestamp close_lb close_ls close_lseg
        close_pb close_pl close_ps close_sb close_sl col_description concat
        concat_ws contjoinsel contsel convert_from convert_to corr cos
        cot covar_pop covar_samp crypt cstring_in cstring_out cstring_recv
        cstring_send cume_dist current_database current_query current_schema current_schemas current_setting
        current_user currtid currtid2 currval date date_cmp date_cmp_timestamp date_cmp_timestamptz date_eq
        date_eq_timestamp date_eq_timestamptz date_ge date_ge_timestamp date_ge_timestamptz date_gt date_gt_timestamp
        date_gt_timestamptz date_in date_larger date_le date_le_timestamp date_le_timestamptz date_lt
        date_lt_timestamp date_lt_timestamptz date_mi date_mi_interval date_mii date_ne date_ne_timestamp
        date_ne_timestamptz date_out date_pl_interval date_pli date_recv date_send date_smaller
        date_sortsupport daterange daterange_canonical daterange_subdiff datetime_pl datetimetz_pl
        dblink_connect_u dblink_connect dblink_disconnect dblink_exec dblink_open dblink_fetch dblink_close
        dblink_get_connections dblink_error_message dblink_send_query dblink_is_busy dblink_get_notify
	dblink_get_result dblink_cancel_query dblink_get_pkey dblink_build_sql_insert dblink_build_sql_delete
	dblink_build_sql_update dblink dcbrt dearmor decrypt decrypt_iv degrees dense_rank dexp diagonal
        decimal diameter digest dispell_init dispell_lexize dist_cpoly dist_lb dist_pb
        dist_pc dist_pl dist_ppath dist_ps dist_sb dist_sl div
        dlog1 dlog10 domain_in domain_recv dpow dround dsimple_init
        dsimple_lexize dsnowball_init dsnowball_lexize dsqrt dsynonym_init dsynonym_lexize dtrunc
        elem_contained_by_range encrypt encrypt_iv enum_cmp enum_eq enum_first enum_ge
        enum_gt enum_in enum_larger enum_last enum_le enum_lt enum_ne
        enum_out enum_range enum_recv enum_send enum_smaller eqjoinsel eqsel
        euc_cn_to_mic euc_cn_to_utf8 euc_jis_2004_to_shift_jis_2004 euc_jis_2004_to_utf8
	euc_jp_to_mic euc_jp_to_sjis euc_jp_to_utf8
        euc_kr_to_mic euc_kr_to_utf8 euc_tw_to_big5 euc_tw_to_mic euc_tw_to_utf8 every exp
        factorial family fdw_handler_in fdw_handler_out first_value float4 float48div
        float48eq float48ge float48gt float48le float48lt float48mi float48mul
        float48ne float48pl float4_accum float4abs float4div float4eq float4ge
        float4gt float4in float4larger float4le float4lt float4mi float4mul
        float4ne float4out float4pl float4recv float4send float4smaller float4um
        float4up float8 float84div float84eq float84ge float84gt float84le
        float84lt float84mi float84mul float84ne float84pl float8_accum float8_avg
	float8_combine float8_regr_combine float8_corr float8_covar_pop float8_covar_samp
	float8_regr_accum float8_regr_avgx float8_regr_avgy float8_regr_intercept
        float8_regr_r2 float8_regr_slope float8_regr_sxx float8_regr_sxy float8_regr_syy
	float8_stddev_pop float8_stddev_samp
        float8_var_pop float8_var_samp float8abs float8div float8eq float8ge float8gt
        float8in float8larger float8le float8lt float8mi float8mul float8ne
        float8out float8pl float8recv float8send float8smaller float8um float8up
        floor flt4_mul_cash flt8_mul_cash fmgr_c_validator fmgr_internal_validator fmgr_sql_validator format
        format_type gb18030_to_utf8 gbk_to_utf8 gen_random_bytes gen_salt generate_series generate_subscripts
        get_current_ts_config getdatabaseencoding getpgusername gin_cmp_prefix gin_cmp_tslexeme gin_extract_tsquery gin_extract_tsvector
        gin_tsquery_consistent ginarrayconsistent ginarrayextract ginbeginscan ginbuild ginbuildempty ginbulkdelete
        gincostestimate ginendscan gingetbitmap gininsert ginmarkpos ginoptions ginqueryarrayextract
        ginrescan ginrestrpos ginvacuumcleanup gist_box_compress gist_box_consistent gist_box_decompress gist_box_penalty
        gist_box_picksplit gist_box_same gist_box_union gist_circle_compress gist_circle_consistent gist_point_compress gist_point_consistent
        gist_point_distance gist_poly_compress gist_poly_consistent gistbeginscan gistbuild gistbuildempty gistbulkdelete
        gistcostestimate gistendscan gistgetbitmap gistgettuple gistinsert gistmarkpos gistoptions
        gistrescan gistrestrpos gistvacuumcleanup gtsquery_compress gtsquery_consistent gtsquery_decompress gtsquery_penalty
        gtsquery_picksplit gtsquery_same gtsquery_union gtsvector_compress gtsvector_consistent gtsvector_decompress gtsvector_penalty
        gtsvector_picksplit gtsvector_same gtsvector_union gtsvectorin gtsvectorout has_any_column_privilege has_column_privilege
        has_database_privilege has_foreign_data_wrapper_privilege has_function_privilege has_language_privilege
	has_schema_privilege has_sequence_privilege has_server_privilege has_table_privilege has_tablespace_privilege
	has_type_privilege hash_aclitem hash_array hash_numeric hash_range hashbeginscan hashbpchar hashbuild
	hashbuildempty hashbulkdelete hashchar hashcostestimate hash_aclitem_extended 
        hashendscan hashenum hashfloat4 hashfloat8 hashgetbitmap hashgettuple hashinet hashinsert hashint2
	hashint2extended hashint2vector hashint4 hashint4extended hashint8 hashint8extended hashmacaddr
	hashfloat4extended hashfloat8extended hashcharextended hashoidextended hashnameextended hashmarkpos
	hashoidvectorextended hashmacaddrextended hashinetextended hashname hashoid hashoidvector hashoptions
       	hash_numeric_extended hashmacaddr8extended hash_array_extended hashrescan hashrestrpos hashtext
        hashbpcharextended time_hash_extended timetz_hash_extended interval_hash_extended timestamp_hash_extended
	uuid_hash_extended pg_lsn_hash_extended hashenumextended jsonb_hash_extended hash_range_extended
	hashtextextended hashvacuumcleanup hashvarlena height hmac host hostmask iclikejoinsel
        iclikesel icnlikejoinsel icnlikesel icregexeqjoinsel icregexeqsel icregexnejoinsel icregexnesel
        inet_client_addr inet_client_port inet_in inet_out inet_recv inet_send inet_server_addr
        inet_server_port inetand inetmi inetmi_int8 inetnot inetor inetpl
        int int2 int24div int24eq int24ge int24gt int24le int24lt integer
        int24mi int24mul int24ne int24pl int28div int28eq int28ge
        int28gt int28le int28lt int28mi int28mul int28ne int28pl
        int2_accum int2_avg_accum int2_mul_cash int2_sum int2abs int2and int2div
        int2eq int2ge int2gt int2in int2larger int2le int2lt
        int2mi int2mod int2mul int2ne int2not int2or int2out
        int2pl int2recv int2send int2shl int2shr int2smaller int2um
        int2up int2vectoreq int2vectorin int2vectorout int2vectorrecv int2vectorsend int2xor
        int4 int42div int42eq int42ge int42gt int42le int42lt
        int42mi int42mul int42ne int42pl int48div int48eq int48ge
        int48gt int48le int48lt int48mi int48mul int48ne int48pl
        int4_accum int4_avg_accum int4_mul_cash int4_sum int4abs int4and int4div
        int4eq int4ge int4gt int4in int4inc int4larger int4le
        int4lt int4mi int4mod int4mul int4ne int4not int4or
        int4out int4pl int4range int4range_canonical int4range_subdiff int4recv int4send
        int4shl int4shr int4smaller int4um int4up int4xor int8
        int82div int82eq int82ge int82gt int82le int82lt int82mi
        int82mul int82ne int82pl int84div int84eq int84ge int84gt
        int84le int84lt int84mi int84mul int84ne int84pl int8_accum
        int8_avg int8_avg_accum int8_sum int8abs int8and int8div int8eq
        int8ge int8gt int8in int8inc int8inc_any int8inc_float8_float8 int8larger
        int8le int8lt int8mi int8mod int8mul int8ne int8not
        int8or int8out int8pl int8pl_inet int8range int8range_canonical int8range_subdiff
        int8recv int8send int8shl int8shr int8smaller int8um int8up
        int8xor integer_pl_date inter_lb inter_sb inter_sl internal_in internal_out
        interval_accum interval_avg interval_cmp interval_div interval_eq interval_ge interval_gt
        interval_hash interval_in interval_larger interval_le interval_lt interval_mi interval_mul
        interval_ne interval_out interval_pl interval_pl_date interval_pl_time interval_pl_timestamp interval_pl_timestamptz
        interval_pl_timetz interval_recv interval_send interval_smaller interval_transform interval_um intervaltypmodin
        intervaltypmodout intinterval isclosed isempty ishorizontal iso8859_1_to_utf8 iso8859_to_utf8
        iso_to_koi8r iso_to_mic iso_to_win1251 iso_to_win866 isopen isparallel isperp
        isvertical johab_to_utf8 json_agg jsonb_agg json_array_elements jsonb_array_elements json_array_elements_text jsonb_array_elements_text
        json_array_length jsonb_array_length json_build_array json_build_object json_each jsonb_each json_each_text
        jsonb_each_text json_extract_path jsonb_extract_path json_extract_path_text jsonb_extract_path_text json_in
	json_object json_object_agg jsonb_object_agg json_object_keys jsonb_object_keys json_out json_populate_record
	jsonb_populate_record json_populate_recordset jsonb_pretty jsonb_populate_recordset json_recv json_send
	jsonb_set json_typeof jsonb_typeof json_to_record jsonb_to_record json_to_recordset jsonb_to_recordset
	justify_interval koi8r_to_iso koi8r_to_mic koi8r_to_utf8 koi8r_to_win1251 koi8r_to_win866 koi8u_to_utf8
	jsonb_path_query jsonb_build_object
        lag language_handler_in language_handler_out last_value lastval latin1_to_mic latin2_to_mic latin2_to_win1250
        latin3_to_mic latin4_to_mic lead like_escape likejoinsel
        likesel line line_distance line_eq line_horizontal line_in line_interpt
        line_intersect line_out line_parallel line_perp line_recv line_send line_vertical
        ln lo_close lo_creat lo_create lo_export lo_import lo_lseek
        lo_open lo_tell lo_truncate lo_unlink log loread lower_inc
        lower_inf lowrite lseg lseg_center lseg_distance lseg_eq lseg_ge
        lseg_gt lseg_horizontal lseg_in lseg_interpt lseg_intersect lseg_le lseg_length
        lseg_lt lseg_ne lseg_out lseg_parallel lseg_perp lseg_recv lseg_send
        lseg_vertical macaddr_and macaddr_cmp macaddr_eq macaddr_ge macaddr_gt macaddr_in
        macaddr_le macaddr_lt macaddr_ne macaddr_not macaddr_or macaddr_out macaddr_recv
        macaddr_send makeaclitem make_interval make_tsrange masklen max mic_to_ascii mic_to_big5 mic_to_euc_cn
        mic_to_euc_jp mic_to_euc_kr mic_to_euc_tw mic_to_iso mic_to_koi8r mic_to_latin1 mic_to_latin2
        mic_to_latin3 mic_to_latin4 mic_to_sjis mic_to_win1250 mic_to_win1251 mic_to_win866 min
        mktinterval mode mod money mul_d_interval name nameeq namege
        namegt nameiclike nameicnlike nameicregexeq nameicregexne namein namele
        namelike namelt namene namenlike nameout namerecv nameregexeq
        nameregexne namesend neqjoinsel neqsel netmask network network_cmp
        network_eq network_ge network_gt network_le network_lt network_ne network_sub
        network_subeq network_sup network_supeq nextval nlikejoinsel nlikesel notlike
        npoints nth_value ntile numeric numeric_abs numeric_accum numeric_add
        numeric_avg numeric_avg_accum numeric_cmp numeric_div numeric_div_trunc numeric_eq numeric_exp
        numeric_fac numeric_ge numeric_gt numeric_in numeric_inc numeric_larger numeric_le
        numeric_ln numeric_log numeric_lt numeric_mod numeric_mul numeric_ne numeric_out
        numeric_power numeric_recv numeric_send numeric_smaller numeric_sqrt numeric_stddev_pop numeric_stddev_samp
        numeric_sub numeric_transform numeric_uminus numeric_uplus numeric_var_pop numeric_var_samp numerictypmodin
        numerictypmodout numnode numrange numrange_subdiff obj_description oid oideq
        oidge oidgt oidin oidlarger oidle oidlt oidne
        oidout oidrecv oidsend oidsmaller oidvectoreq oidvectorge oidvectorgt
        oidvectorin oidvectorle oidvectorlt oidvectorne oidvectorout oidvectorrecv oidvectorsend
        oidvectortypes on_pb on_pl on_ppath on_ps on_sb on_sl
        opaque_in opaque_out overlaps path path_add path_add_pt path_center
        path_contain_pt path_distance path_div_pt path_in path_inter path_length path_mul_pt
        path_n_eq path_n_ge path_n_gt path_n_le path_n_lt path_npoints path_out
        path_recv path_send path_sub_pt pclose percent_rank percentile_cont percentile_disc
	pg_advisory_lock pg_advisory_lock_shared pg_advisory_unlock pg_advisory_unlock_all pg_advisory_unlock_shared
	pg_advisory_xact_lock pg_advisory_xact_lock_shared pg_available_extension_versions pg_available_extensions
	pg_backend_pid pg_cancel_backend pg_char_to_encoding pg_collation_for pg_collation_is_visible pg_column_size
	pg_conf_load_time pg_conversion_is_visible pg_create_restore_point pg_current_xlog_insert_location
        pg_current_xlog_location pg_cursor pg_database_size pg_describe_object pg_encoding_max_length
	pg_encoding_to_char pg_export_snapshot pg_extension_config_dump pg_extension_update_paths pg_function_is_visible
	pg_get_constraintdef pg_get_expr pg_get_function_arguments pg_filenode_relation pg_indexam_has_property
        pg_get_function_identity_arguments pg_get_function_result pg_get_functiondef pg_get_indexdef pg_get_keywords
        pg_get_ruledef pg_get_serial_sequence pg_get_triggerdef pg_get_userbyid pg_get_viewdef pg_has_role
	pg_indexes_size pg_is_in_recovery pg_is_other_temp_schema pg_is_xlog_replay_paused pg_last_xact_replay_timestamp
	pg_last_xlog_receive_location pg_last_xlog_replay_location pg_listening_channels pg_lock_status pg_ls_dir
	pg_my_temp_schema pg_node_tree_in pg_node_tree_out pg_node_tree_recv pg_node_tree_send pg_notify
	pg_opclass_is_visible pg_operator_is_visible pg_opfamily_is_visible pg_options_to_table pg_index_has_property
        pg_postmaster_start_time pg_prepared_statement pg_prepared_xact pg_read_binary_file pg_read_file
	pg_relation_filenode pg_relation_filepath pg_relation_size pg_reload_conf pg_rotate_logfile
	pg_sequence_parameters pg_show_all_settings pg_size_pretty pg_sleep pg_start_backup pg_index_column_has_property
        pg_stat_clear_snapshot pg_stat_file pg_stat_get_activity pg_stat_get_analyze_count pg_stat_get_autoanalyze_count
	pg_stat_get_autovacuum_count pg_get_object_address pg_identify_object_as_address pg_stat_get_backend_activity
	pg_stat_get_backend_activity_start pg_stat_get_backend_client_addr pg_stat_get_backend_client_port
        pg_stat_get_backend_dbid pg_stat_get_backend_idset pg_stat_get_backend_pid pg_stat_get_backend_start
	pg_stat_get_backend_userid pg_stat_get_backend_waiting pg_stat_get_backend_xact_start
	pg_stat_get_bgwriter_buf_written_checkpoints pg_stat_get_bgwriter_buf_written_clean
        pg_stat_get_bgwriter_maxwritten_clean pg_stat_get_bgwriter_requested_checkpoints
	pg_stat_get_bgwriter_stat_reset_time pg_stat_get_bgwriter_timed_checkpoints pg_stat_get_blocks_fetched
	pg_stat_get_blocks_hit pg_stat_get_buf_alloc pg_stat_get_buf_fsync_backend pg_stat_get_buf_written_backend
	pg_stat_get_checkpoint_sync_time pg_stat_get_checkpoint_write_time pg_stat_get_db_blk_read_time
	pg_stat_get_db_blk_write_time pg_stat_get_db_blocks_fetched pg_stat_get_db_blocks_hit
	pg_stat_get_db_conflict_all pg_stat_get_db_conflict_bufferpin pg_stat_get_db_conflict_lock
	pg_stat_get_db_conflict_snapshot pg_stat_get_db_conflict_startup_deadlock pg_stat_get_db_conflict_tablespace
        pg_stat_get_db_deadlocks pg_stat_get_db_numbackends pg_stat_get_db_stat_reset_time pg_stat_get_db_temp_bytes
	pg_stat_get_db_temp_files pg_stat_get_db_tuples_deleted pg_stat_get_db_tuples_fetched
	pg_stat_get_db_tuples_inserted pg_stat_get_db_tuples_returned pg_stat_get_db_tuples_updated
        pg_stat_get_db_xact_commit pg_stat_get_db_xact_rollback pg_stat_get_dead_tuples pg_stat_get_function_calls
	pg_stat_get_function_self_time pg_stat_get_function_total_time pg_stat_get_last_analyze_time
	pg_stat_get_last_autoanalyze_time pg_stat_get_last_autovacuum_time pg_stat_get_last_vacuum_time
	pg_stat_get_live_tuples pg_stat_get_numscans pg_stat_get_tuples_deleted pg_stat_get_tuples_fetched
        pg_stat_get_tuples_hot_updated pg_stat_get_tuples_inserted pg_stat_get_tuples_returned
	pg_stat_get_tuples_updated pg_stat_get_vacuum_count pg_stat_get_wal_senders pg_stat_get_xact_blocks_fetched
	pg_stat_get_xact_blocks_hit pg_stat_get_xact_function_calls pg_stat_get_xact_function_self_time
        pg_stat_get_xact_function_total_time pg_stat_get_xact_numscans pg_stat_get_xact_tuples_deleted
	pg_stat_get_xact_tuples_fetched pg_stat_get_xact_tuples_hot_updated pg_stat_get_xact_tuples_inserted
	pg_stat_get_xact_tuples_returned pg_stat_get_xact_tuples_updated pg_stat_reset pg_stat_reset_shared
	pg_stat_reset_single_function_counters pg_stat_reset_single_table_counters pg_stop_backup pg_switch_xlog
	pg_table_is_visible pg_table_size pg_tablespace_databases pg_tablespace_location pg_tablespace_size
	pg_terminate_backend pg_timezone_abbrevs pg_timezone_names pg_total_relation_size pg_trigger_depth
	pg_try_advisory_lock pg_try_advisory_lock_shared pg_try_advisory_xact_lock pg_try_advisory_xact_lock_shared
        pg_ts_config_is_visible pg_ts_dict_is_visible pg_ts_parser_is_visible pg_ts_template_is_visible
        pg_type_is_visible pg_typeof pg_xact_commit_timestamp pg_last_committed_xact pg_xlog_location_diff
	pg_xlog_replay_pause pg_xlog_replay_resume pg_xlogfile_name pg_xlogfile_name_offset pgp_key_id pgp_pub_decrypt
	pgp_pub_decrypt_bytea pgp_pub_encrypt pgp_pub_encrypt_bytea pgp_sym_decrypt pgp_sym_decrypt_bytea
        pgp_sym_encrypt pgp_sym_encrypt_bytea pi plainto_tsquery plpgsql_call_handler plpgsql_inline_handler
	plpgsql_validator point point_above point_add point_below point_distance point_div point_eq
        point_horiz point_in point_left point_mul point_ne point_out point_recv
        point_right point_send point_sub point_vert poly_above poly_below poly_center
        poly_contain poly_contain_pt poly_contained poly_distance poly_in poly_left poly_npoints
        poly_out poly_overabove poly_overbelow poly_overlap poly_overleft poly_overright poly_recv
        poly_right poly_same poly_send polygon popen positionjoinsel positionsel
        postgresql_fdw_validator pow power prsd_end prsd_headline prsd_lextype prsd_nexttoken
        prsd_start pt_contained_circle pt_contained_poly querytree
        quote_nullable radians radius random range_adjacent range_after range_before
        range_cmp range_contained_by range_contains range_contains_elem range_eq range_ge range_gist_compress
        range_gist_consistent range_gist_decompress range_gist_penalty range_gist_picksplit range_gist_same range_gist_union range_gt
        range_in range_intersect range_le range_lt range_minus range_ne range_out
        range_overlaps range_overleft range_overright range_recv range_send range_typanalyze range_union
        rank record_eq record_ge record_gt record_in record_le record_lt
        record_ne record_out record_recv record_send regclass regclassin regclassout
        regclassrecv regclasssend regconfigin regconfigout regconfigrecv regconfigsend regdictionaryin
        regdictionaryout regdictionaryrecv regdictionarysend regexeqjoinsel regexeqsel regexnejoinsel regexnesel
        regexp_matches regexp_replace regexp_split_to_array regexp_split_to_table regoperatorin regoperatorout regoperatorrecv
        regoperatorsend regoperin regoperout regoperrecv regopersend regprocedurein regprocedureout
        regprocedurerecv regproceduresend regprocin regprocout regprocrecv regprocsend regr_avgx
        regr_avgy regr_count regr_intercept regr_r2 regr_slope regr_sxx regr_sxy
        regr_syy regtypein regtypeout regtyperecv regtypesend reltime reltimeeq
        reltimege reltimegt reltimein reltimele reltimelt reltimene reltimeout
        reltimerecv reltimesend reverse round row_number row_to_json
        scalargtjoinsel scalargtsel scalarltjoinsel scalarltsel
        session_user set_config set_masklen setseed setval setweight shell_in
        shell_out shift_jis_2004_to_euc_jis_2004 shift_jis_2004_to_utf8 shobj_description sign similar_escape sin
        sjis_to_euc_jp sjis_to_mic sjis_to_utf8 slope smgreq smgrin smgrne
        smgrout spg_kd_choose spg_kd_config spg_kd_inner_consistent spg_kd_picksplit spg_quad_choose spg_quad_config
        spg_quad_inner_consistent spg_quad_leaf_consistent spg_quad_picksplit spg_text_choose spg_text_config spg_text_inner_consistent spg_text_leaf_consistent
        spg_text_picksplit spgbeginscan spgbuild spgbuildempty spgbulkdelete spgcanreturn spgcostestimate
        spgendscan spggetbitmap spggettuple spginsert spgmarkpos spgoptions spgrescan
        spgrestrpos spgvacuumcleanup sqrt statement_timestamp stddev stddev_pop stddev_samp
        string_agg string_agg_finalfn string_agg_transfn string_to_array strip sum
        tan text text_ge text_gt text_larger
        text_le text_lt text_pattern_ge text_pattern_gt text_pattern_le text_pattern_lt text_smaller
        textanycat textcat texteq texticlike texticnlike texticregexeq texticregexne
        textin textlen textlike textne textnlike textout textrecv
        textregexeq textregexne textsend thesaurus_init thesaurus_lexize tideq tidge
        tidgt tidin tidlarger tidle tidlt tidne tidout
        tidrecv tidsend tidsmaller time time_cmp time_eq time_ge
        time_gt time_hash time_in time_larger time_le time_lt time_mi_interval
        time_mi_time time_ne time_out time_pl_interval time_recv time_send time_smaller
        time_transform timedate_pl timemi timenow timepl timestamp timestamp_cmp
        timestamp_cmp_date timestamp_cmp_timestamptz timestamp_eq timestamp_eq_date timestamp_eq_timestamptz timestamp_ge timestamp_ge_date
        timestamp_ge_timestamptz timestamp_gt timestamp_gt_date timestamp_gt_timestamptz timestamp_hash timestamp_in timestamp_larger
        timestamp_le timestamp_le_date timestamp_le_timestamptz timestamp_lt timestamp_lt_date timestamp_lt_timestamptz timestamp_mi
        timestamp_mi_interval timestamp_ne timestamp_ne_date timestamp_ne_timestamptz timestamp_out timestamp_pl_interval timestamp_recv
        timestamp_send timestamp_smaller timestamp_sortsupport timestamp_transform timestamptypmodin timestamptypmodout timestamptz
        timestamptz_cmp timestamptz_cmp_date timestamptz_cmp_timestamp timestamptz_eq timestamptz_eq_date timestamptz_eq_timestamp timestamptz_ge
        timestamptz_ge_date timestamptz_ge_timestamp timestamptz_gt timestamptz_gt_date timestamptz_gt_timestamp timestamptz_in timestamptz_larger
        timestamptz_le timestamptz_le_date timestamptz_le_timestamp timestamptz_lt timestamptz_lt_date timestamptz_lt_timestamp timestamptz_mi
        timestamptz_mi_interval timestamptz_ne timestamptz_ne_date timestamptz_ne_timestamp timestamptz_out timestamptz_pl_interval timestamptz_recv
        timestamptz_send timestamptz_smaller timestamptztypmodin timestamptztypmodout timetypmodin timetypmodout timetz
        timetz_cmp timetz_eq timetz_ge timetz_gt timetz_hash timetz_in timetz_larger
        timetz_le timetz_lt timetz_mi_interval timetz_ne timetz_out timetz_pl_interval timetz_recv
        timetz_send timetz_smaller timetzdate_pl timetztypmodin timetztypmodout timezone tinterval
        tintervalct tintervalend tintervaleq tintervalge tintervalgt tintervalin tintervalle
        tintervalleneq tintervallenge tintervallengt tintervallenle tintervallenlt tintervallenne tintervallt
        tintervalne tintervalout tintervalov tintervalrecv tintervalrel tintervalsame tintervalsend
        tintervalstart to_json to_tsquery to_tsvector transaction_timestamp trigger_out trunc ts_debug
        ts_headline ts_lexize ts_match_qv ts_match_tq ts_match_tt ts_match_vq ts_parse
        ts_rank ts_rank_cd ts_rewrite ts_stat ts_token_type ts_typanalyze tsmatchjoinsel
        tsmatchsel tsq_mcontained tsq_mcontains tsquery_and tsquery_cmp tsquery_eq tsquery_ge
        tsquery_gt tsquery_le tsquery_lt tsquery_ne tsquery_not tsquery_or tsqueryin
        tsqueryout tsqueryrecv tsquerysend tsrange tsrange_subdiff tstzrange tstzrange_subdiff
        tsvector_cmp tsvector_concat tsvector_eq tsvector_ge tsvector_gt tsvector_le tsvector_lt
        tsvector_ne tsvectorin tsvectorout tsvectorrecv tsvectorsend txid_current txid_current_snapshot
        txid_snapshot_in txid_snapshot_out txid_snapshot_recv txid_snapshot_send txid_snapshot_xip txid_snapshot_xmax txid_snapshot_xmin
        txid_visible_in_snapshot uhc_to_utf8 unknownin unknownout unknownrecv unknownsend unnest
        upper_inc upper_inf utf8_to_ascii utf8_to_big5 utf8_to_euc_cn utf8_to_euc_jis_2004 utf8_to_euc_jp
        utf8_to_euc_kr utf8_to_euc_tw utf8_to_gb18030 utf8_to_gbk utf8_to_iso8859 utf8_to_iso8859_1 utf8_to_johab
        utf8_to_koi8r utf8_to_koi8u utf8_to_shift_jis_2004 utf8_to_sjis utf8_to_uhc utf8_to_win uuid_cmp
        uuid_eq uuid_ge uuid_gt uuid_hash uuid_in uuid_le uuid_lt
        uuid_ne uuid_out uuid_recv uuid_send var_pop var_samp varbit
        varbit_in varbit_out varbit_recv varbit_send varbit_transform varbitcmp varbiteq
        varbitge varbitgt varbitle varbitlt varbitne varbittypmodin varbittypmodout
        varchar varying varchar_transform varcharin varcharout varcharrecv varcharsend varchartypmodin
        varchartypmodout variance version void_in void_out void_recv void_send
        width width_bucket win1250_to_latin2 win1250_to_mic win1251_to_iso win1251_to_koi8r win1251_to_mic
        win1251_to_win866 win866_to_iso win866_to_koi8r win866_to_mic win866_to_win1251 win_to_utf8 xideq
        xideqint4 xidin xidout xidrecv xidsend xml xml_in xmlcomment xpath xpath_exists table_to_xmlschema
        query_to_xmlschema cursor_to_xmlschema table_to_xml_and_xmlschema query_to_xml_and_xmlschema
        schema_to_xml schema_to_xmlschema schema_to_xml_and_xmlschema database_to_xml database_to_xmlschema xmlroot
        database_to_xml_and_xmlschema table_to_xml query_to_xmlcursor_to_xml xmlcomment xmlconcat xmlelement xmlforest
        xml_is_well_formed_content xml_is_well_formed_document xml_is_well_formed xml_out xml_recv xml_send xmlagg
	xmlpi query_to_xml cursor_to_xml xmlserialize
        );

    my @copy_keywords = ( 'STDIN', 'STDOUT' );

    my %symbols = (
        '='  => '=', '<'  => '&lt;', '>' => '&gt;', '|' => '|', ',' => ',', '.' => '.', '+' => '+', '-' => '-',
        '*' => '*', '/' => '/', '!=' => '!=', '%' => '%', '<=' => '&lt;=', '>=' => '&gt;=', '<>' => '&lt;&gt;'
    );

    my @brackets = ( '(', ')' );

    # All setting and modification of dicts is done, can set them now to $self->{'dict'}->{...}
    $self->{ 'dict' }->{ 'pg_keywords' }   = \@pg_keywords;
    $self->{ 'dict' }->{ 'pg_types' }      = \@pg_types;
    $self->{ 'dict' }->{ 'sql_keywords' }  = \@sql_keywords;
    $self->{ 'dict' }->{ 'pg_functions' }  = ();
    map { $self->{ 'dict' }->{ 'pg_functions' }{$_} = ''; } @pg_functions;
    $self->{ 'dict' }->{ 'copy_keywords' } = \@copy_keywords;
    $self->{ 'dict' }->{ 'symbols' }       = \%symbols;
    $self->{ 'dict' }->{ 'brackets' }      = \@brackets;

    return;
}

=head2 _remove_dynamic_code

Internal function used to hide dynamic code in plpgsql to the parser.
The original values are restored with function _restore_dynamic_code().

=cut

sub _remove_dynamic_code
{
    my ($self, $str, $code_sep) = @_;

    my @dynsep = ();
    push(@dynsep, $code_sep) if ($code_sep && $code_sep ne "'");

    # Try to auto detect the string separator if none are provided.
    # Note that default single quote separtor is natively supported.
    if ($#dynsep == -1) {
        # if a dollar sign is found after EXECUTE then the following string
        # until an other dollar is found will be understand as a text delimiter
        @dynsep = $$str =~ /EXECUTE\s+(\$[^\$\s]*\$)/igs;
    }

    my $idx = 0;
    foreach my $sep (@dynsep) {
        while ($$str =~ s/(\Q$sep\E.*?\Q$sep\E)/TEXTVALUE$idx/s) {
            $self->{dynamic_code}{$idx} = $1;
            $idx++;
        }
    }

    # Replace any COMMENT constant between single quote 
    while ($$str =~ s/IS\s+('(?:.*?)')\s*;/IS TEXTVALUE$idx;/s) {
        $self->{dynamic_code}{$idx} = $1;
        $idx++;
    }
}

=head2 _restore_dynamic_code

Internal function used to restore plpgsql dynamic code in plpgsql
that was removed by the _remove_dynamic_code() method.

=cut

sub _restore_dynamic_code
{
        my ($self, $str) = @_;

        $$str =~ s/TEXTVALUE(\d+)/$self->{dynamic_code}{$1}/gs;

}

=head2 _quote_operator

Internal function used to quote operator with multiple character
to be tokenized as a single word.
The original values are restored with function _restore_operator().

=cut

sub _quote_operator
{
    my ($self, $str) = @_;

    while ($$str =~ s/((?:CREATE|DROP|ALTER)\s+OPERATOR\s+(?:IF\s+EXISTS)?)\s*((:?[a-z0-9]+\.)?[\+\-\*\/<>=\~\!\@\#\%\^\&\|\`\?]+)\s*/$1 "$2" /is) {
        push(@{ $self->{operator} }, $2) if (!grep(/^\Q$2\E$/, @{ $self->{operator} }));
    }

    my $idx = 0;
    while ($$str =~ s/(NEGATOR|COMMUTATOR)\s*=\s*([^,\)\s]+)/\U$1\E$idx/is) {
	    $self->{uc($1)}{$idx} = "$1 = $2";
	    $idx++;
    }
}

=head2 _restore_operator

Internal function used to restore operator that was removed
by the _quote_operator() method.

=cut

sub _restore_operator
{
        my ($self, $str) = @_;

	foreach my $op (@{ $self->{operator} })
	{
		$$str =~ s/"$op"/$op/gs;
	}
	if (exists $self->{COMMUTATOR}) {
		$$str =~ s/COMMUTATOR(\d+)/$self->{COMMUTATOR}{$1}/igs;
	}
	if (exists $self->{NEGATOR}) {
		$$str =~ s/NEGATOR(\d+)/$self->{NEGATOR}{$1}/igs;
	}
}

=head2 _remove_comments

Internal function used to remove comments in SQL code
to simplify the work of the wrap_lines. Comments must be
restored with the _restore_comments() method.

=cut

sub _remove_comments
{
    my $self = shift;

    my $idx = 0;

    while ($self->{ 'content' } =~ s/(\/\*(.*?)\*\/)/PGF_COMMENT${idx}A/s) {
        $self->{'comments'}{"PGF_COMMENT${idx}A"} = $1;
        $idx++;
    }

    my @lines = split(/\n/, $self->{ 'content' });
    for (my $j = 0; $j <= $#lines; $j++) {
        $lines[$j] //= '';
        # Extract multiline comments as a single placeholder
        my $old_j = $j;
        my $cmt = '';
        while ($j <= $#lines && $lines[$j] =~ /^(\s*\-\-.*)$/) {
            $cmt .= "$1\n";
            $j++;
        }
        if ( $j > $old_j ) {
            chomp($cmt);
            $lines[$old_j] =~ s/^(\s*\-\-.*)$/PGF_COMMENT${idx}A/;
            $self->{'comments'}{"PGF_COMMENT${idx}A"} = $cmt;
            $idx++;
            $j--;
            while ($j > $old_j) {
                delete $lines[$j];
                $j--;
            }
        }
        if ($lines[$j] =~ s/(\s*\-\-.*)$/PGF_COMMENT${idx}A/) {
            $self->{'comments'}{"PGF_COMMENT${idx}A"} = $1;
            chomp($self->{'comments'}{"PGF_COMMENT${idx}A"});
            $idx++;
        }

        # Mysql supports differents kinds of comment's starter
        if ( ($lines[$j] =~ s/(\s*COMMENT\s+'.*)$/PGF_COMMENT${idx}A/) ||
        ($lines[$j] =~ s/(\s*\# .*)$/PGF_COMMENT${idx}A/) ) {
            $self->{'comments'}{"PGF_COMMENT${idx}A"} = $1;
            chomp($self->{'comments'}{"PGF_COMMENT${idx}A"});
            # Normalize start of comment
            $self->{'comments'}{"PGF_COMMENT${idx}A"} =~ s/^(\s*)COMMENT/$1\-\- /;
            $self->{'comments'}{"PGF_COMMENT${idx}A"} =~ s/^(\s*)\#/$1\-\- /;
            $idx++;
        }
    }
    $self->{ 'content' } = join("\n", @lines);

    # Replace subsequent comment by a single one
    while ($self->{ 'content' } =~ s/(PGF_COMMENT\d+A\s*PGF_COMMENT\d+A)/PGF_COMMENT${idx}A/s) {
        $self->{'comments'}{"PGF_COMMENT${idx}A"} = $1;
        $idx++;
    }
}

=head2 _restore_comments (OBSOLETE)

Internal function used to restore comments in SQL code
that was removed by the _remove_comments() method.

=cut

sub _restore_comments
{
    my $self = shift;

    while ($self->{ 'content' } =~ s/(PGF_COMMENT\d+A)[\n]*/$self->{'comments'}{$1}\n/s) { delete $self->{'comments'}{$1}; };
}

=head2 wrap_lines

Internal function used to wrap line at a certain length.

=cut

sub wrap_lines
{
    my $self = shift;

    return if (!$self->{'wrap_limit'} || !$self->{ 'content' });

    $self->_remove_comments();

    my @lines = split(/\n/, $self->{ 'content' });
    $self->{ 'content' } = '';

    foreach my $l (@lines)
    {
	# Remove and store the indentation of the line
	my $indent = '';
	if ($l =~ s/^(\s+)//) {
		$indent = $1;
	}
	if (length($l) > $self->{'wrap_limit'} + ($self->{'wrap_limit'}*10/100))
	{
		$Text::Wrap::columns = $self->{'wrap_limit'};
		my $t = wrap($indent, " "x$self->{ 'spaces' } . $indent, $l);
		$self->{ 'content' } .= "$t\n";
	} else {
		$self->{ 'content' } .= $indent . "$l\n";
	}
    }

    $self->_restore_comments() if ($self->{ 'content' });

    return;
}


=head1 AUTHOR

pgFormatter is an original work from Gilles Darold

=head1 BUGS

Please report any bugs or feature requests to: https://github.com/darold/pgFormatter/issues

=head1 COPYRIGHT

Copyright 2012-2019 Gilles Darold. All rights reserved.

=head1 LICENSE

pgFormatter is free software distributed under the PostgreSQL Licence.

A modified version of the SQL::Beautify Perl Module is embedded in pgFormatter
with copyright (C) 2009 by Jonas Kramer and is published under the terms of
the Artistic License 2.0.

=cut

1;
