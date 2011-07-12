# various helper methods for Pod parsing and processing
class Perl6::Pod {
    our sub any_block($/) {
        my @children := [];
        for $<pod_content> {
            # check if it's a pod node or an array of strings
            if pir::isa($_.ast, 'ResizablePMCArray') {
                for $_.ast { @children.push($_) }
            } else {
                @children.push($_.ast);
            }
        }
        my $content := serialize_array(@children);
        if $<type>.Str ~~ /^item \d*$/ {
            my $level      := nqp::substr($<type>.Str, 4);
            my $level_past;
            if $level ne '' {
                $level_past := $*ST.add_constant(
                    'Int', 'int', +$level,
                )<compile_time_value>;
            } else {
                $level_past := $*ST.find_symbol(['Mu']);
            }
            my $past := serialize_object(
                'Pod::Item', :level($level_past),
                :content($content<compile_time_value>)
            );
            return $past<compile_time_value>;
        }
        my $name := $*ST.add_constant('Str', 'str', $<type>.Str);
        my $past := serialize_object(
            'Pod::Block::Named', :name($name<compile_time_value>),
            :content($content<compile_time_value>),
        );
        return $past<compile_time_value>;
    }

    our sub raw_block($/) {
        my $str := $*ST.add_constant(
            'Str', 'str',
            pir::isa($<pod_content>, 'ResizablePMCArray')
                ?? pir::join('', $<pod_content>) !! ~$<pod_content>,
        );
        my $content := serialize_array([$str<compile_time_value>]);
        my $type := $<type>.Str eq 'code' ?? 'Pod::Block::Code'
                                          !! 'Pod::Block::Comment';
        my $past := serialize_object(
            $type, :content($content<compile_time_value>)
        );
        return $past<compile_time_value>;
    }

    our sub formatted_text($a) {
        my $r := subst($a, /\s+/, ' ', :global);
        $r    := subst($r, /^^\s*/, '');
        $r    := subst($r, /\s*$$/, '');
        return $r;
    }
    our sub table($/) {
        my @rows := [];
        for $<table_row> {
            @rows.push($_.ast);
        }
        @rows := process_rows(@rows);
        # we need to know 3 things about the separators:
        #   is there more than one
        #   where is the first one
        #   are they different from each other
        # Given no separators, our table is just an ordinary, one-lined
        # table.
        # If there is one separator, the table has a header and
        # the actual content. If the first header is further than on the
        # second row, then the header is multi-lined.
        # If there's more than one separator, the table has a multi-line
        # header and a multi-line content.
        # Tricky, isn't it? Let's try to handle it sanely
        my $sepnum        := 0;
        my $firstsepindex := 0;
        my $differentseps := 0;
        my $firstsep;
        my $i := 0;
        while $i < +@rows {
            unless pir::isa(@rows[$i], 'ResizablePMCArray') {
                $sepnum := $sepnum + 1;
                unless $firstsepindex { $firstsepindex := $i }
                if $firstsep {
                    if $firstsep ne @rows[$i] { $differentseps := 1 }
                } else {
                    $firstsep := @rows[$i];
                }
            }
            $i := $i + 1;
        }

        my $headers := [];
        my $content := [];

        if $sepnum == 0 {
            # ordinary table, no headers, one-lined rows
            $content := @rows;
        } elsif $sepnum == 1 {
            if $firstsepindex == 1 {
                # one-lined header, one-lined rows
                $headers := @rows.shift;
                @rows.shift; # remove the separator
                $content := @rows;
            } else {
                # multi-line header, one-lined rows
                my $i := 0;
                my @hlines := [];
                while $i < $firstsepindex {
                    @hlines.push(@rows.shift);
                    $i := $i + 1;
                }
                $headers := merge_rows(@hlines);
                @rows.shift; # remove the separator
                $content := @rows;
            }
        } else {
            my @hlines := [];
            my $i := 0;
            if $differentseps {
                while $i < $firstsepindex {
                    @hlines.push(@rows.shift);
                    $i := $i + 1;
                }
                @rows.shift;
                $headers := merge_rows(@hlines);
            }
            # let's go through the rows and merge the multi-line ones
            my @newrows := [];
            my @tmp  := [];
            $i       := 0;
            while $i < +@rows {
                if pir::isa(@rows[$i], 'ResizablePMCArray') {
                    @tmp.push(@rows[$i]);
                } else {
                    @newrows.push(merge_rows(@tmp));
                    @tmp := [];
                }
                $i := $i + 1;
            }
            if +@tmp > 0 {
                @newrows.push(merge_rows(@tmp));
            }
            $content := @newrows;
        }

        my $past := serialize_object(
            'Pod::Block::Table',
            :headers(serialize_aos($headers)<compile_time_value>),
            :content(serialize_aoaos($content)<compile_time_value>),
        );
        make $past<compile_time_value>;
    }

    our sub process_rows(@rows) {
        # find the longest leading whitespace and strip it
        # from every row, also remove trailing \n
        my $w := -1; # the longest leading whitespace
        for @rows -> $row {
            next if $row ~~ /^^\s*$$/;
            my $match := $row ~~ /^^\s+/;
            my $n := $match.to;
            if $n < $w || $w == -1 {
                $w := $n;
            }
        }
        my $i := 0;
        while $i < +@rows {
            unless @rows[$i] ~~ /^^\s*$$/ {
                @rows[$i] := nqp::substr(@rows[$i], $w);
            }
            # chomp
            @rows[$i] := subst(@rows[$i], /\n$/, '');
            $i := $i + 1;
        }
        # split the row between cells
        my @res;
        $i := 0;
        while $i < +@rows {
            my $v := @rows[$i];
            if $v ~~ /^'='+ || ^'-'+ || ^'_'+ || ^\h*$/ {
                @res[$i] := $v;
            } elsif $v ~~ /\h'|'\h/ {
                my $m := $v ~~ /
                    :ratchet ([<!before [\h+ || ^^] '|' [\h+ || $$]> .]*)
                    ** [ [\h+ || ^^] '|' [\h || $$] ]
                /;
                @res[$i] := [];
                for $m[0] { @res[$i].push(formatted_text($_)) }
            } elsif $v ~~ /\h'+'\h/ {
                my $m := $v ~~ /
                    :ratchet ([<!before [\h+ || ^^] '+' [\h+ || $$]> .]*)
                    ** [ [\h+ || ^^] '+' [\h+ || $$] ]
                /;
                @res[$i] := [];
                for $m[0] { @res[$i].push(formatted_text($_)) }
            } else {
                # now way to easily split rows
                return splitrows(@rows);
            }
            $i := $i + 1;
        }
        return @res;
    }

    our sub merge_rows(@rows) {
        my @result := @rows[0];
        my $i := 1;
        while $i < +@rows {
            my $j := 0;
            while $j < +@rows[$i] {
                if @rows[$i][$j] {
                    @result[$j] := formatted_text(
                        ~@result[$j] ~ ' ' ~ ~@rows[$i][$j]
                    );
                }
                $j := $j + 1;
            }
            $i := $i + 1;
        }
        return @result;
    }

    # takes an array of strings (rows of a table)
    # returns array of arrays of strings (cells)
    our sub splitrows(@rows) {
        my @suspects := []; #positions that might be cell delimiters
                            # values: 1     – impossibru!
                            #         unset – mebbe

        my $i := 0;
        while $i < +@rows {
            unless @rows[$i] ~~ /^'='+ || ^'-'+ || ^'_'+ || ^\h*$ / {
                my @line := pir::split('', @rows[$i]);
                my $j := 0;
                while $j < +@line {
                    unless @suspects[$j] {
                        if @line[$j] ne ' ' {
                            @suspects[$j] := 1;
                        }
                    }
                    $j := $j + 1;
                }
            }
            $i := $i + 1;
        }

        # now let's skip the single spaces
        $i := 0;
        while $i < +@suspects {
            unless @suspects[$i] {
                if @suspects[$i-1] && @suspects[$i+1] {
                    @suspects[$i] := 1;
                }
            }
            $i := $i + 1;
        }

        # now we're doing some magic which will
        # turn those positions into cell ranges
        # so for values: 13 14 15   30 31 32 33
        # we get [0, 13, 16, 30, 34, 0] (last 0 as a guard)

        my $wasone := 1;
        $i := 0;
        my @ranges := [];
        @ranges.push(0);

        while $i < +@suspects {
            if !$wasone && @suspects[$i] == 1 {
                @ranges.push($i);
                $wasone := 1;
            } elsif $wasone && @suspects[$i] != 1 {
                @ranges.push($i);
                $wasone := 0;
            }
            $i := $i + 1;
        }
        @ranges.push(0); # guard

        my @ret := [];
        for @rows -> $row {
            if $row ~~ /^'='+ || ^'-'+ || ^'_'+ || ^\h*$/ {
                @ret.push($row);
                next;
            }
            my @tmp := [];
            for @ranges -> $a, $b {
                next if $a > nqp::chars($row);
                if $b {
                    @tmp.push(
                        formatted_text(nqp::substr($row, $a, $b - $a))
                    );
                } else {
                    @tmp.push(
                        formatted_text(nqp::substr($row, $a))
                    );
                }
            }
            @ret.push(@tmp);
        }
        return @ret;
    }

    # serializes the given array
    our sub serialize_array(@arr) {
        return $*ST.add_constant('Array', 'type_new', |@arr);
    }

    # serializes an array of strings
    our sub serialize_aos(@arr) {
        my @cells := [];
        for @arr -> $cell {
            my $p := $*ST.add_constant('Str', 'str', ~$cell);
            @cells.push($p<compile_time_value>);
        }
        return serialize_array(@cells);
    }

    # serializes an array of arrays of strings
    our sub serialize_aoaos(@rows) {
        my @content := [];
        for @rows -> $row {
            my $p := serialize_aos($row);
            @content.push($*ST.scalar_wrap($p<compile_time_value>));
        }
        return serialize_array(@content);
    }

    # serializes object of the given type
    our sub serialize_object($type, *@pos, *%named) {
        return $*ST.add_constant($type, 'type_new', |@pos, |%named);
    }
}

# vim: ft=perl6
