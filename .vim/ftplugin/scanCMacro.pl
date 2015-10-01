#!/usr/bin/perl -w
use Modern::Perl "2013";
use feature qw(switch);
use charnames ':full';
use English '-no_match_vars';
use autodie;
use diagnostics;
no warnings qw(experimental::smartmatch);
use Carp qw(carp croak);
use File::Slurp;
use Scalar::Util qw(dualvar);
use Try::Tiny;

use constant {INCLUDE_MAX_LEVEL => 2, COMMENTS => qr(\s+(?:/\*.*?\*/|//.*$))};
my $num_dec = qr([+-]? (?: \.\d+(fl?)? | [1-9]\d*(\.\d+)? | [1-9]\d*(?:[fu]?l|(ll)?u)) )xi;
my $num_oct = qr([+-]? 0[0-7]*(?: ul\{,2\} | l{1,2}u)? )xi;	  # '0' matched here. No floating-point or eng?
my $num_hex = qr([+-]? 0x(?: [[:xdigit:]]*\.[[:xdigit:]]+p[+-]?\d+[fl]? | [[:xdigit:]]+\.p[+-]?\d+[fl]? |
	   [[:xdigit:]]+(?:u|ul|ull|lu|llu)? ) )xi;	   # 0x3.p+6f, 0x.bp-5F;
my $num_eng = qr([+-]?(?: \d+\.\d*e[+-]?\d+[fl]? | \.\d+(e[+-]?\d+)?[fl]? | \d+e[+-]?\d+[fl]?) )xi;
my $number = qr( $num_dec | $num_oct | $num_hex | $num_eng )xi; # prioritized.

# translate incompatible C Macro symbols to local subroutine
my %evaltab=(defined=>'sym_defined');
my (%symtab,%def_,%ndef_); my ($report,@path)='';

# modifies reference. pack into perl-recognizable number
sub to_number($){
   my ($ref,$pos)=shift;
   if( $$ref =~ qr(^$num_hex|$num_oct$) ){
	$$ref =~ qr(0[ox].+\d)i;
	$pos = $LAST_MATCH_END[0]//-1;
   }else{
	$$ref =~ qr(.+\d);
	$pos = $LAST_MATCH_END[0]//-1
   }
   try{
   	$$ref = eval substr $$ref, 0, $pos;
	$$ref||=0	    # don't miss-interprete literal 0
   }catch{		  # nothing to do for unintelligible expr
   }finally{
   	1
   }
}

# look for included headers
sub find_file($){
   my ($filename,$fullname)=shift;
   state %processed;	  # local cache
   unless(exists $processed{$filename}){
	foreach my $Path (@path){
	   if(-f ($fullname=$Path.'/'.$filename)){
		$processed{$filename}=$fullname;
		return $fullname
	   }
	}
   }
   0      # silence if not found
}

# evaluate value of a macro symbol by tracing symbols. No logic evaluation is done.
sub sym_trace($){
   my $sym=shift;
   return $sym unless $sym;
   while($sym and exists $symtab{$sym} and defined $symtab{$sym} and
   	$sym ne $symtab{$sym}){
	$sym=delete local $symtab{$sym};		    # avoid cyclic defs
   }
   $sym
}

# emulated defined(xxx) block
sub sym_defined($){
   my $sym=shift;
   $sym and exists $symtab{$sym}
}

# break an expr into tokens. Comments need to be removed before tokenization
sub sym_tokenize($){
   my $line=shift;		  # FIXME: not capturing complex C number patterns
   my @tokens;
   my $operator=qr((?:\+\+|--|&&|\|\||<<|>>|##|\W));
   my $word=qr(([a-zA-Z_]\w*));
   while( $line =~ /\G\s*(?<token>$number|$operator|$word)/g ){
	push @tokens,$+{token}
   }
   @tokens
}

sub matched_paren($$){	  # \@token_list, $start_index
   my ($list,$start,$paired,$paren) = (shift,shift,0,0);# quotes parenthesized item. e.g. ('foo','##','bar','foos') ==>
   foreach my $index ($start .. @$list-1){	  # ('"foo','##','bar"','foos')
	if($$list[$index] eq '##'){
	   $paired=1;
	}elsif($$list[$index] eq '('){
	   ++$paren; ++$start;
	}elsif($$list[$index] eq ')'){
	   --$paren;
	}elsif($paired){
	   $paired=0;
	}else{
	   $$list[$index].='"'; $$list[$start]='"'.$$list[$start];
	   last;
	}
   }
}

sub sym_eval($){
   my $sym=shift;
   return $sym if !defined $sym or !$sym or
	($sym =~ /^$number$/ and to_number \$sym);
   if($sym and my @tokens=sym_tokenize $sym){
	foreach my $index (1 .. @tokens-2){
	   if($tokens[$index] eq '##'){		# concatenation
	   	$tokens[$index-1].=$tokens[$index+1];
	   	$tokens[$index]= $tokens[$index+1]='';
	   }
	}
	foreach my $index (0 .. @tokens-1){	 # macro expansion
	   my $token=$tokens[$index];
	   next unless defined $token;
	   if($token =~ /^$number$/){
	   	to_number \$token;
	   }else{
		if(exists $evaltab{$token}){
               # extend `eval''s power: strip nesting parentheses & quote bare words
		   matched_paren \@tokens, $index+1;   # parenthesis and concats
	   	   $tokens[$index] = $evaltab{$token};
		}else{
		   $tokens[$index]=sym_trace $token
		}
	   }
	}
	$sym=join '',@tokens;
   }
   no warnings;		  # return unevaluable symbols verbatim
   try{ $sym = eval $sym or die 'except' }catch{};
   $sym//''
}

sub scan{
   my ($filename,$level)=@_;
   my $cfilename=$filename;
   return if $level>INCLUDE_MAX_LEVEL;
   croak "Cannot read $filename" unless -r $filename;
   my @lines=read_file $filename;
   my ($cur_sym,$block_val)=(0,0);
   foreach my $line_number(1 .. @lines){
	if($line_number<@lines
            and substr($lines[$line_number-1],-2) eq "\\\n"){
	   $lines[$line_number]=substr($lines[$line_number-1],0,-2).$lines[$line_number];
	   next
	}
	given($lines[$line_number-1]){
	   when( qr(\A#\s*include\s+<\s*(?<header>\S+)\s*>)
               or qr(\A#\s*include\s+"\s*(?<header>\S+)\s*") ){
		$filename=find_file $+{header};
		scan($filename,$level+1)if $filename;
	   }when( qr(\A#\s*define\s*(?<symbol>\w+)\b\s*(?<rest>.+)?$) ){
	   	my ($symbol,$value)=($+{symbol}, $+{rest});
		if(defined $value and $value =~ COMMENTS){   # strip trailing comments
	   	   $value = substr $value, 0, ($LAST_MATCH_START[0]//-1)
		}
		$symtab{$symbol}=sym_eval($_=$value)	   # given/when modifies topic var
	   }when( qr(\A#\s*undef\s+(?<symbol>\w+)) ){
		delete @symtab{$+{symbol}}
	   }when( !$level and $lines[$line_number-1]=~qr(\A#\s*ifdef\s+(?<symbol>\w+)) ){	   # ifdef/ifndef: only matters in top-level
		$def_{$cur_sym=dualvar 1,$+{symbol}}=$line_number;
	   }when( !$level and $lines[$line_number-1]=~qr(\A#\s*ifndef\s+(?<symbol>\w+)) ){
		$ndef_{$cur_sym=dualvar -1,$+{symbol}}=$line_number;
	   }when( !$level and $lines[$line_number-1]=~qr(\A#\s*if\s+(?<expr>\S.*\S?)\s*$) ){   # if/elif/else
		$block_val=sym_eval($_=$+{expr}) ? dualvar(0,'') : dualvar($line_number,'f')
	   }when( !$level
               and $lines[$line_number-1]=~qr(\A#\s*elif\s+(?<expr>\S.*\S?)\s*$) ){
		if($block_val==0 and $block_val eq ''){   # possible only if condition unmatched before
		   $block_val=sym_eval($_=$+{expr}) ? dualvar(0,'')
                  : dualvar($line_number,'f')
		}else{
		   $report.="$cfilename:".(0+$block_val).':'.$line_number."\n";
		   $block_val=dualvar 0,'f';	   # highlight prev block and disable
		}					   # following #elif and #else block
	   }when( !$level and $lines[$line_number-1]=~qr(\A#\s*else\b) ){
		if($block_val>0){
		   $report.="$cfilename:".(0+$block_val).':'.$line_number."\n";
		   $block_val=dualvar 0,'f'
		}else{   # has any previous block been successfully matched before?
		   $block_val = $block_val eq 'f' ? 0 : (dualvar $line_number,'f')
		}
	   }when( !$level and $lines[$line_number-1]=~qr(\A#\s*endif\s*) ){
		if($block_val>0){
		   $report.="$cfilename:".(0+$block_val).':'.$line_number."\n"
		}elsif(exists $def_{$cur_sym.''} and !exists $symtab{$cur_sym.''}){
		   $report.="$cfilename:".$def_{$cur_sym.''}.':'.$line_number."\n"
		}elsif(exists $ndef_{$cur_sym.''} and exists $symtab{$cur_sym.''}){
		   $report.="$cfilename:".$ndef_{$cur_sym.''}.':'.$line_number."\n"
		}
		delete $def_{$cur_sym} if $cur_sym>0;
		delete $ndef_{$cur_sym} if $cur_sym<0;
		$cur_sym=0; $block_val=dualvar 0,''
	   }
	}
   }
}

sub printMacro(){	  # print all macro values
   foreach my $k(sort {$a cmp $b} keys %symtab){
	say "'".$k."'".($symtab{$k} ? " =>\t'$symtab{$k}'" : '')
   }
}

sub main{
   my ($filename,$path)=@_;
   croak 'Usage: perl scanMacro.pl foo.c [path1,path2,...]'
      unless defined $filename;
   croak "Cannot read $filename" unless -r $filename;
   @path = defined $path ? split(',',$path) : qw( . /usr/include );
   if($filename =~ qr(.*\.(?:cc|C|cxx|cpp|hh|H|hpp|hxx)$) ){
	my @cpp=grep{/[0-9.]*/} read_dir('/usr/include/c++');
	push @path,'/usr/include/c++/'.$cpp[-1] if @cpp;
   }
   scan $filename,0;
   chomp $report; print $report
}

exit !main @ARGV;

