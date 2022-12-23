#!/usr/bin/perl 

#
#./SMS.pl <Serial port> 
#
#Changlog: 
#
##2008-09-28:
#  1. 修复有时候截取汉字的时候出现错误的问题！（有时候长度会截取文字的一半）
#2008-06-16:
#  1. 修正了发送短信中英文和数字混合出现不能发送的错误， 主要修改了，OutSendSMSMessage的函数 
#2008-02-20:
#  1. 修改了发送消息的方式
#  #步骤：
#  #    1、 比较相邻两条的phone和realname(源号码），如果相同，比较时间戳，在规定的时间间隔外则发送。
#  #    2、 如果相邻两条的phone和realname(源号码）不同则发送。
#2007-12-14:
#  1.修改了查询数据库的条件， 去掉了send_time的判断。
#  2.修改了Setup.sh为install.sh
#  3.新增了uninstall.sh为来删除SMSServer
#2007-12-05:
#  1.新增了Debug函数
#
#2007-12-04:
#  1.开始着手开发Megaeyes SMS Server.<zth>
#  2.编写基础模块<zth>
#  3.编写安装模块和开始停止模块（setup.sh,start.sh,stop.sh) <zth>



use strict;

use File::Path;
use File::Copy;
use Data::Dumper;
use IniConf;
use Expect;
use Data::Dumper;
use DBI;
use Device::Gsm::Pdu;
use Text::Iconv;
use Digest::MD5;

#use Encode::CN;
#BEGIN{ $Unicode::EastAsianWidth::Asian = 1};
use Unicode::EastAsianWidth;
use Unicode::Transform qw(:all);
use Encode qw/encode decode/;

die "Usage: $0 <comm port> " unless scalar(@ARGV) == 1;
my $port = $ARGV[0];

my $DEBUG = 6;
my $LOG_DIR = "/var/log";
my $LogFile = "$LOG_DIR/SMS.log.$port";
my $LICENSE_FILE= "/etc/License.lic";
$SIG{TERM} = \&SIGTermProc;
$SIG{INT} = \&SIGTermProc;
$SIG{CHLD} = \&SIGChldProc;
my $SIGCHLD_CU = 0;

my $dbh;

&Debug(1, "========== MegaEyes SMS Program started for port $port ==========");

my $device = "/dev/$port";

my $INI = &ReadIni("/etc/smsserver.ini");
my $SMS = $INI->{"SMS_$port"};
$SMS->{Speed} ||= 9600;
$SMS->{ModemInit} ||= "AT&F";
$SMS->{ModemInit1} ||= 'AT+CSDH=1';
$SMS->{MySQLHost} ||= "localhost";
$SMS->{MySQLDatabase} ||= "smsgateway";
$SMS->{UserName} ||= "root";
$SMS->{Password} ||="root01";
$SMS->{CheckInterval} ||= 5; 
$SMS->{CheckIntervalTime} ||= 5;
$SMS->{CheckTwoSameRecordTime} ||= 6;
$SMS->{InEmailFrom} ||= "Megaeyes Technologies";
$SMS->{DebugLevel} ||= 5;
$SMS->{SplitFlag} ||= 70;
$DEBUG = $SMS->{DebugLevel};
my $cu = Expect->spawn("cu -l $device -s $SMS->{Speed} --nostop");
die "Spawn Error: $!\n" unless $cu;

$cu->log_stdout(1);

# 注释: 2008年07月08日 zth
#my $v = &CheckRegisterInfo();
#if(!$v){
#   &Debug(1, "Sorry! you are not a availd user, please contact owner support department!\n");
#   print "License is not availd! Please link owner http://www.megaeyes.com \n";
#   exit;
#}
#初始化短信设备.

&PrepareModem();
&ConnectMySQL($SMS->{MySQLHost}, $SMS->{MySQLDatabase}, $SMS->{UserName}, $SMS->{Password});
my $prevtime = 0;
while (1) {
    #&GetMessages(); //注释接收短信功能
    my $currtime = time;
    if ($currtime - $prevtime >= $SMS->{CheckIntervalTime}) {
        &Debug(10, "Checking new short messages from MySQL database ");
        &SendMessagesFromMySQL();
        $prevtime = $currtime;
    }
    sleep $SMS->{CheckInterval};
}


#检查软件的合法性
sub CheckRegisterInfo {
   my $body;
   my $hwaddr;
   open LIC_FILE, "<:bytes","$LICENSE_FILE" or die "License file not exists!! ";
   read LIC_FILE, $body, 17, 0;
   close LIC_FILE ;
   $hwaddr = `/sbin/ifconfig eth0 | grep HWaddr | awk \'{print \$5}\' `;
   $hwaddr =~ s/:/G/gi;
   $hwaddr =~ s/0/M/gi;



   
   $hwaddr =~ s/B/t/gi;
   $hwaddr =~ s/M/t/gi;
   $hwaddr =~ s/5/t/gi;

   $hwaddr =~ s/B/G/gi;
   $hwaddr =~ s/C/H/gi;
   $hwaddr =~ s/D/I/gi;

   $hwaddr =~ s/4/2/gi;
   $hwaddr =~ s/5/3/gi;   
   $hwaddr =~ s/6/4/gi;   
   $hwaddr =~ s/8/6/gi;   
   $hwaddr =~ s/9/7/gi; 
  
   
   $body =~ s/^ +//;
   $body =~ s/ +$//;
 #  &Debug(1, "Body  : $body");
 #  &Debug(1, "Hwaddr: $hwaddr"); 
 #  if ($body =~ /^$hwaddr$/i){
    if ($hwaddr =~ /^$body$/i){
        return 1;
      }else{
        return 0;
   }
  
  
}

#连接MySQL数据库
sub ConnectMySQL {
   my ($host, $database, $username, $password ) = @_;
   $dbh = DBI->connect("DBI:mysql:database=$database:$host", "$username", "$password", {RaiseError => 1});
   die "Connect MySQL Server ERROR: $!\n" unless $dbh;
   &Debug(1, "Connect to MySQL database $host successful!\n");

   #设置中文字符集.
   my $sth = $dbh->prepare('SET NAMES \'gbk\'');
   $sth->execute();
}


#检查新的短消息从MySQL数据库
#SELECT send_id, phone, content, sendcounter ,realname, createtime FROM sendqueue WHERE status=0 ORDER BY phone, realname, createtime 
#步骤：
#    1、 比较相邻两条的phone和realname(源号码），如果相同，比较时间戳，在规定的时间间隔外则发送。
#    2、 如果相邻两条的phone和realname(源号码）不同则发送。
sub CheckNewMessageFromMySQL {
   die "Connect to MySQL database Error !\n" unless $dbh;
   my $curtime = &GetYYYYMMDDDateFormat();
   my $sth = $dbh->prepare('SELECT send_id, phone, content, sendcounter, realname, create_time FROM sendqueue WHERE status=0 ORDER BY phone, realname, create_time');
   $sth->execute();
   my $retrycounter = 0;
   my ($res, $sendstatus, $content, $phone, $srclencontent, $curlencontent);
   my ($oldphone, $oldrealname, $oldtime);
   my ($resphone, $resrealname, $restime);
   my ($hexcode, $hexlen);

   while($res = $sth->fetchrow_hashref()) {
       $resphone = $res->{'phone'};
       $resrealname = $res->{'realname'};
       $restime = $res->{'create_time'};

       if ( $oldphone == $resphone && 
           $oldrealname == $resrealname &&
             (&SubTractionTwoDateTime($oldtime, $restime) < $SMS->{CheckTwoSameRecordTime})) {
         #表示最近有相同的记录已经处理，所以不再处理，直接删除。
         #更新发送状态
         #&UpdateSMSState2MySQL($res->{'send_id'}, 4);
         #移动数据到发送历史表 sendqueue_history
		
         &CopySendQueueDate2SendHistory($res->{'send_id'});
         &DeleteRecordFromMySQL($res->{'send_id'});
         #continue;
         next;
       }

      #如果字段phone和realname和先前的记录相同，则更新时间，否则更新整个记录。
      if ( $oldphone == $resphone && $oldrealname == $resrealname ) {
            $oldtime = $restime;
      }else {
           $oldphone = $resphone;
           $oldrealname = $resrealname;
           $oldtime = $restime;
      }
      
      #没有国家表示则加入国家表示。
      $phone = $res->{'phone'};  
      if (index($phone, '+86', 0) == -1){
          $phone = "+86".$phone;
        }
      &Debug(2, "Checking new messages from mysql server! PhoneNumber:[ $phone ]");
       
      $retrycounter = 0;
      $srclencontent = 0;
      $curlencontent = 0;
      
      do{
       #更新状态为正在发送中...
        &UpdateSMSState2MySQL($res->{'send_id'}, 4);
        &Debug(2, "src content length is  ".length($res->{'content'}));
        my $offset = 0;
        $res->{'content'} =~ s/^\s+|\s+$//g;
        Encode::_utf8_on($res->{'content'});
        my $uncontent = $res->{'content'};
        &Debug(11, "Length of content is ". length($res->{'content'}));
        if (length($res->{'content'}) > 70 )
         {
          $srclencontent = length($res->{'content'});
          ($hexcode, $hexlen) =&Text2PDUFormat($res->{'content'});
          
          #短信内容超过70个字符.
          #&Debug(2, "Setting the max length limit ( $SMS->{SplitFlag} )");
          do{
             #print("offset $offset, total length ". length($res->{'content'}));
             $content = substr($hexcode, $offset, 280);
			 &Debug(2, "Current content length is ". $hexlen);
             $curlencontent = length(substr($hexcode, $offset, 280));

             $sendstatus = &OutSendSMSMessage2({To => $phone, Text => $content});
     
             $offset += 280;
             sleep 2; 
          }until($offset >= $hexlen*2)
        }else{
           $content = $res->{'content'};
           $sendstatus = &OutSendSMSMessage({To => $phone, Text => $content});
        }
        #假如发送失败则判断重试次数
        if (!$sendstatus) {
           $retrycounter ++;
           sleep 3;
           }

       }until ( $sendstatus || ($retrycounter > $res->{'sendcounter'} ))
       

       #更新发送状态
       &UpdateSMSState2MySQL($res->{'send_id'}, ($sendstatus ? 1: 2));
       #移动数据到发送历史表 sendqueue_history
       &CopySendQueueDate2SendHistory($res->{'send_id'});
       &DeleteRecordFromMySQL($res->{'send_id'});
    }
   $sth->finish();

}

#检查新的短消息从MySQL数据库
#SELECT send_id, phone, content, sendcounter ,realname, createtime FROM sendqueue WHERE status=0 ORDER BY phone, realname, createtime 
#步骤：
#    1、 比较相邻两条的phone和realname(源号码），如果相同，比较时间戳，在规定的时间间隔外则发送。
#    2、 如果相邻两条的phone和realname(源号码）不同则发送。
sub CheckNewMessageFromMySQL1 {
   die "Connect to MySQL database Error !\n" unless $dbh;
   my $curtime = &GetYYYYMMDDDateFormat();
   my $sth = $dbh->prepare('SELECT send_id, phone, content, sendcounter, realname, create_time FROM sendqueue WHERE status=0 ORDER BY phone, realname, create_time');
   $sth->execute();
   my $retrycounter = 0;
   my ($res, $sendstatus, $content, $phone, $srclencontent, $curlencontent);
   my ($oldphone, $oldrealname, $oldtime);
   my ($resphone, $resrealname, $restime);

   while($res = $sth->fetchrow_hashref()) {
       $resphone = $res->{'phone'};
       $resrealname = $res->{'realname'};
       $restime = $res->{'create_time'};

       if ( $oldphone == $resphone && 
           $oldrealname == $resrealname &&
             (&SubTractionTwoDateTime($oldtime, $restime) < $SMS->{CheckTwoSameRecordTime})) {
         #表示最近有相同的记录已经处理，所以不再处理，直接删除。
         #更新发送状态
         #&UpdateSMSState2MySQL($res->{'send_id'}, 4);
         #移动数据到发送历史表 sendqueue_history
         &CopySendQueueDate2SendHistory($res->{'send_id'});
         &DeleteRecordFromMySQL($res->{'send_id'});
         #continue;
         next;
       }

      #如果字段phone和realname和先前的记录相同，则更新时间，否则更新整个记录。
      if ( $oldphone == $resphone && $oldrealname == $resrealname ) {
            $oldtime = $restime;
      }else {
           $oldphone = $resphone;
           $oldrealname = $resrealname;
           $oldtime = $restime;
      }
      
      #没有国家表示则加入国家表示。
      $phone = $res->{'phone'};  
      if (index($phone, '+86', 0) == -1){
          $phone = "+86".$phone;
        }
      &Debug(2, "Checking new messages from mysql server! PhoneNumber:[ $phone ]");
       
      $retrycounter = 0;
      $srclencontent = 0;
      $curlencontent = 0;
      
      do{
       #更新状态为正在发送中...
        &UpdateSMSState2MySQL($res->{'send_id'}, 4);
        &Debug(2, "src content length is  ".length($res->{'content'}));
        my $offset = 0;
        $res->{'content'} =~ s/^\s+|\s+$//g;
        Encode::_utf8_on($res->{'content'});
        my $uncontent = $res->{'content'};
        &Debug(11, "Length of content is ". length($res->{'content'}));
        if (length($res->{'content'}) > 70 )
         {
          $srclencontent = length($res->{'content'});
          #短信内容超过70个字符.
          #&Debug(2, "Setting the max length limit ( $SMS->{SplitFlag} )");
          do{
             #print("offset $offset, total length ". length($res->{'content'}));
             $content = substr($res->{'content'}, $offset, 70);
			 &Debug(2, "Current content length is ". length($content));
             $curlencontent = length(substr($res->{'content'}, $offset, 70));

             $sendstatus = &OutSendSMSMessage({To => $phone, Text => $content});
     
             $offset += 70;
             sleep 2; 
          }until($offset >= length($res->{'content'}))
        }else{
           $content = $res->{'content'};
           $sendstatus = &OutSendSMSMessage({To => $phone, Text => $content});
        }
        #假如发送失败则判断重试次数
        if (!$sendstatus) {
           $retrycounter ++;
           sleep 3;
           }

       }until ( $sendstatus || ($retrycounter > $res->{'sendcounter'} ))
       

       #更新发送状态
       &UpdateSMSState2MySQL($res->{'send_id'}, ($sendstatus ? 1: 2));
       #移动数据到发送历史表 sendqueue_history
       &CopySendQueueDate2SendHistory($res->{'send_id'});
       &DeleteRecordFromMySQL($res->{'send_id'});
    }
   $sth->finish();

}


#断开MySQL数据库
sub DisconnectMySQL {
  if ($dbh) {
    $dbh->disconnect();
  }
}

#拷贝发送数据到历史表
sub CopySendQueueDate2SendHistory {
    die "Connect MySQL database Error ! \n" unless $dbh;
    &Debug(1, "copying current record to sendqueue_history  table!");
    my $send_id = shift();
    my $sth = $dbh->prepare('SELECT * FROM sendqueue WHERE send_id=?');
    my $sth1 = $dbh->prepare('INSERT INTO sendqueue_history VALUES(?,?,?,?,?,?,?,?,?)');
    $sth->execute($send_id);
    my $res = $sth->fetchrow_hashref();
    $sth1->execute($res->{'send_id'}, $res->{'sms_id'}, $res->{'realname'}, $res->{'phone'}, $res->{'content'},
                   $res->{'sendcounter'}, $res->{'create_time'}, $res->{'send_time'}, $res->{'status'});
    
    $sth1->finish();
    $sth->finish();
}

#删除记录
sub DeleteRecordFromMySQL {
   die "Connect MySQL database Error !\n" unless $dbh;
   my $send_id = shift();
   my $sth = $dbh->prepare('DELETE FROM sendqueue WHERE send_id=?');
   $sth->execute($send_id);
   $sth->finish();
}

sub UpdateSMSState2MySQL {
   die "Connect to MySQL database Error !\n" unless $dbh;
   my ($send_id, $status) = @_;
   my $curtime = &GetYYYYMMDDDateFormat();
   my $sth = $dbh->prepare('UPDATE sendqueue SET status=?,send_time=? WHERE send_id=?');
   $sth->execute($status, $curtime, $send_id);
   $sth->finish();
}

#初始化短信设备
sub PrepareModem {
    $cu->send_slow(0.1, "$SMS->{ModemInit}\r");
    $cu->expect(10, "OK") or &Abort("Cannot Initialize GSM Modem!");
    $cu->send_slow(0.1, "$SMS->{ModemInit1}\r");
    $cu->expect(10, "OK") or &Abort("Cannot Initialize GSM Modem!");
    &ModemCheckPIN();
    &ModemCheckReg();
    &Debug(1, "===== SMS Modem preparation successful =====");
}

sub Abort {
   my $arg = shift();
   print $arg;
   print "\n";
}

#检查设备的pin值
sub ModemCheckPIN {
    &Debug(1, "Checking PIN Status");
    $cu->send_slow(0.1, "AT+CPIN?\r");
    &ModemExpect(10, "READY", "ERROR");
    if ($cu->exp_match eq "READY") {
        &Debug(2, "PIN Status OK.");
        return;
    }
    &Debug(1, "Sending PIN to SMS Modem");
    print $cu "AT+CPIN=$SMS->{PIN}\r";
    &ModemExpect(30, "READY", "ERROR");
    &Abort("Incorrect PIN!") if $cu->exp_match eq "ERROR";
    &Debug(2, "PIN Accepted!");
}
#检查设备的注册情况
sub ModemCheckReg {
    my $TRIES = 5;
    &Debug(1, "Checking Network Registration Status");
    my $IsRegd = 0;
    for my $i (1 .. $TRIES) {
        $cu->send_slow(0.1, "AT+CREG?\r");    
        &ModemExpect(30, "OK", "ERROR");
        if ($cu->exp_match eq "ERROR") {
            &Debug(2, "Received \"ERROR\" response!");
            next;
        }
        if (($cu->exp_before =~ /CREG: *0,1/i) || ($cu->exp_match eq "OK") ) {
            &Debug(2, "Modem successfully registered.");
            $IsRegd = 1;
            last;
        } else {
            &Debug(2, "Modem not properly registered yet!");
        }
    }
    &Abort("Modem cannot be registered to Home Network!")
        unless $IsRegd;
}

#接收短信
sub GetMessages {
	print $cu "AT+CMGF=1\r";
	&ModemExpect(60,"OK");
	&Debug(6, "Checking for Incoming SMS Messages");
	print $cu "AT+CMGL=\"ALL\"\r";
	&ModemExpect(60, "OK");
	my @aMsg = grep /^\+CMGL: *\d+,"REC (READ|UNREAD)",/,
	split(/\r?\n/, $cu->exp_before);
	my @aMsgID = map { /^\+CMGL: *(\d+),/; $1 } @aMsg;
	map { &InRetrieveMsg($_) } @aMsgID;
	}

#读取收到的短信
sub InRetrieveMsg {
    my $MsgID = shift;
    &Debug (2, "Retrieving Incoming Message No. $MsgID");
    print $cu "AT+CMGR=$MsgID\r";
    &ModemExpect(30, "OK", "ERROR");
    if ($cu->exp_match eq "ERROR") {
        &Debug(2, "SMS Modem returned \"ERROR\"");
        return;
    }
    &Debug(10, $cu->exp_before);
    $cu->exp_before =~ /(\+CMGR:[^\r\n]*)\r?\n/s;
    my ($head, $text) = ($1, $');
    &Debug(10, Dumper $cu->exp_before);
    my ($stat, $from, $tp, $timestamp, $toda, $fo, $pid, $dcs,
        $vp, $length) = &InParseMsgLine($head, ",", "\"");
    $length = length($text);
    $text = substr($text, 0, $length);
    $from =~ s/\//-/g;
    $timestamp =~ s/\//-/g;
    &Debug(10, "Message Data:\nFrom: $from\nDate: $timestamp\nText: $text");
    &InStoreMsg($from, $timestamp, $text);
    &Debug(2, "Deleting Incoming Message No. $MsgID from modem's storage");
    print $cu "AT+CMGD=$MsgID\r";
    &ModemExpect(30, "OK");
}

sub InStoreMsg {
    my ($from, $timestamp, $text) = @_;
    my $file1 = &GetTempPath($SMS->{InDir}, "TMP_", "TXT");
    #  &Debug(5,"The Unicode code is : $text");
    $text = &ChangehexTotxt($text);
    open MAIL, "> $file1";
    print MAIL "From: $SMS->{InEmailFrom}\n";
    print MAIL "Subject: NEWMSG/$from/$timestamp\n\n";
    print MAIL "$text\n";
    close MAIL;
    my $file2 = &GetTempPath($SMS->{InDir}, "IN_", "TXT");
    rename $file1, $file2;
}
## CreateDate : 2003/12/16
sub ConvertHex(){
    my ($replace,$hext,$hexlen,$i,$j,$tempa,$tempb,$res);
    $hext = shift();
    $hexlen = length($hext);
    for($i=0;$i<$hexlen/4;$i++){
       $tempa = substr($hext,0,2);
       $tempb = substr($hext,2,2);
       $res .= $tempb.$tempa;
       $replace = $tempa.$tempb;
       $hext =~s/^$replace//gi;
    }
    $res = "C3BFC3BE".$res;
#    &Debug(5,"The UNICODE HEX is : $res");
    return $res;
}
sub UnicodeToIso88591{
    my $text = shift();
    $text = $text;
    my $converter;
    $converter = Text::Iconv->new("unicode","gb2312");
    $text = $converter->convert($text);
    return $text;     
}

sub ChangehexTotxt{
     &Debug(10,"Starting convert the Hex to Ascii....");
     my $text = shift();
     my $iszimu;
     $iszimu = 0;# this is a flag,if $test are all zimu,store it not convert
     &Debug(10,"The hex before is :$text");
     my $len = length($text);
     &Debug(10,"The hex's length is :$len");
     my ($i,$tempa,$tempb,$tempc,$result);
     for($i =0; $i < $len; $i++){
        $tempa = substr($text,$i,1);
    if(($tempa gt 'f')||($tempa gt 'F')) {
      $iszimu = 1;
    }
     }
     if($iszimu == 1) {
        return $text;
     }
     for($i = 0;$i < $len/4; $i++){
          $tempa = substr($text,0,4);            
#         $tempa = substr($text,i,4);
      $tempb = hex($tempa);
      $tempc = chr_unicode($tempb);
      $result .= encode("euc-cn",$tempc);
      
          $text =~s/^$tempa//gi;    
     }
     &Debug(10,"The Txt after is:$result");
     return $result;
}

sub InParseMsgLine {
    my ($str, $sep, $delim) = @_;
    my @arr = split //, $str;
    my $InFld = 0;
    my $fld = "";
    my @aout;
    while (@arr) {
        my $ch = shift @arr;
        if ($ch eq $delim) {
            $InFld = 1 - $InFld;
        } elsif ($ch eq $sep and !$InFld) {
            push @aout, $fld;
            $fld = "";
        } else {
            $fld .= $ch;
        }
    }
    return @aout;
}
    
    
sub SendMessages {
    opendir DIR, $SMS->{OutDir};
    my @adir = readdir DIR;
    closedir DIR;
    @adir = grep {not $_ =~ /^\.\.?$/} @adir;
#    map { &OutParseMsg("$SMS->{OutDir}/$_") } @adir;
        map { &OutMultiAddr("$SMS->{OutDir}/$_")} @adir;
}

#从数据库中发送短消息
sub SendMessagesFromMySQL {
  die "Connect MySQL database Error !\n" unless $dbh;
  &CheckNewMessageFromMySQL();
}


sub OutParseMsg {
    my $fname = shift;
    open IN, $fname;
    my $invalid = 0;
    my $InBody = 0;
    my ($number, $subject);
    my ($dummy, $DocId);
    my $out = "";
    while (<IN>) {
        if ($InBody) {
            $out .= $_;
            next;
        }
        s/\r?\n//;
        if (/^Subject: (.*)$/) {
            $subject = $1;
            unless ($subject =~ /^NEWMSG\//) {
                $invalid = 1;
                last;
            } else {
                ($dummy, $number, $DocId) = split /\//, $subject;
                next;
            }
        }
        if (/^$/) {
            $InBody = 1;
            next;
        }
    }
    close IN;
    if ($invalid) {
        &Debug(1, "E-Mail does NOT contain a valid SMS Message!\n(Subject = $subject)");
    } else {
        $out = substr($out, 0, 140);
        $number =~ s/[^\+\d]//g;
        my $status = &OutSendMsg({ To => $number, Text => $out });
        &OutSendConfirmation($DocId, ($status ? "SENT" : "FAILED"), $number);
    }
    move $fname, $SMS->{SentDir};
}

sub OutMultiAddr{
    my $fname = shift;
    my @multinumber;
    my $i;
    open IN, $fname;
    my $invalid = 0;
    my $InBody = 0;
    my ($number, $subject);
    my ($dummy, $DocId);
    my $out = "";
    while (<IN>) {
        if ($InBody) {
            $out .= $_;
            next;
        }
        s/\r?\n//;
        if (/^Subject: (.*)$/) {
            $subject = $1;
            unless ($subject =~ /^NEWMSG\//) {
                $invalid = 1;
                last;
            } else {
                ($dummy, $number, $DocId) = split /\//, $subject;
                next;
            }
        }
        if (/^$/) {
            $InBody = 1;
            next;
        }
    }
    close IN;
    if ($invalid) {
        &Debug(1, "The File does NOT contain a valid SMS Message!\n(Subject = $subject)");
    } else {
        $out = substr($out, 0, 140);
        @multinumber = split /,/,$number;
        foreach $i(@multinumber){
             $number = $i;
             $number =~ s/[^\+\d]//g;
             my $status = &OutSendSMSMessage({ To => $number, Text => $out });
            &OutSendConfirmation($DocId, ($status ? "SENT" : "FAILED"), $number);
            } 
    }
    move $fname, $SMS->{SentDir};
}


sub OutSendSMSMessage {
    my $msg = shift;
    my ($pdu,$len,$msgno,$msgtext,$msglen,$pdul);
    &Debug(2, "Sending SMS Message ... ");
    &Debug(10, "Message Data:\nTo: $msg->{To}\nText: $msg->{Text}");
    print $cu "AT+CMGF=0\r";
    #$msglen = length($msg->{Text})+15;
    $msgno = Device::Gsm::Pdu::encode_address($msg->{To});
	($msgtext,$pdul) = &Text2PDUFormat($msg->{Text});
#    $pdul = sprintf("%02X",length($msg->{Text}));
    my $u = $pdul;

    $msglen =  $u + 15;
    $pdul = sprintf("%02X", $u );
    $pdu = uc join('','00','11','00',$msgno,'00','08','01',$pdul,$msgtext);
    &Debug(10,"The PDU is:$pdu,len is :$pdul");
    print $cu "AT+CMGS=$msglen\r";
    &ModemExpect(60, ">");
    print $cu $pdu . chr(26);
    &ModemExpect(60, "OK", "ERROR");
    if ($cu->exp_match eq "ERROR") {
        &Debug(2, "SMS Message could not be sent!");
        return 0;
    } elsif ($cu->exp_match eq "OK") {
        &Debug(2, "SMS Message sent.");
        return 1;
    }
}



sub OutSendSMSMessage2 {
    my $msg = shift;
    my ($pdu,$len,$msgno,$msgtext,$msglen,$pdul);
    &Debug(2, "Sending SMS Message ... ");
    &Debug(10, "Message Data:\nTo: $msg->{To}\nText: $msg->{Text}");
    print $cu "AT+CMGF=0\r";
    #$msglen = length($msg->{Text})+15;
    $msgno = Device::Gsm::Pdu::encode_address($msg->{To});
	$msgtext = $msg->{Text};
	$pdul  = length($msg->{Text})/2;
#    $pdul = sprintf("%02X",length($msg->{Text}));
    my $u = $pdul;

    $msglen =  $u + 15;
    $pdul = sprintf("%02X", $u );
    $pdu = uc join('','00','11','00',$msgno,'00','08','01',$pdul,$msgtext);
    &Debug(10,"The PDU is:$pdu,len is :$pdul");
    print $cu "AT+CMGS=$msglen\r";
    &ModemExpect(60, ">");
    print $cu $pdu . chr(26);
    &ModemExpect(60, "OK", "ERROR");
    if ($cu->exp_match eq "ERROR") {
        &Debug(2, "SMS Message could not be sent!");
        return 0;
    } elsif ($cu->exp_match eq "OK") {
        &Debug(2, "SMS Message sent.");
        return 1;
    }
}


sub OutSendSMSMessage1 {
    my $msg = shift;
    my ($pdu,$len,$msgno,$msgtext,$msglen,$pdul);
    &Debug(2, "Sending SMS Message ... ");
    &Debug(10, "Message Data:\nTo: $msg->{To}\nText: $msg->{Text}");
    print $cu "AT+CMGF=0\r";
    #$msglen = length($msg->{Text})+15;
    $msg->{Pdu_To} = Device::Gsm::Pdu::encode_address($msg->{To});
    ($msg->{UCS2}, $msg->{UCS2_Len}) = &decode_text_UCS2_ex($msg->{Text});
    &Debug(10, "ucs2 message: $msg->{UCS2}");
    &Debug(10, "length txt is ".length($msg->{Text}));
#    $pdul = sprintf("%02X",length($msg->{Text}));

    $msg->{PDU_Len} = $msg->{UCS2_Len}+14;
    $msg->{UCS2_Len} = sprintf("%02X", $msg->{UCS2_Len});
    $pdu = uc join('','00','11','00',$msg->{Pdu_To},'00','08','01',$msg->{UCS2_Len},$msg->{UCS2});
    &Debug(10,"The PDU is:$pdu,len is :$msg->{PDU_Len}");
    print $cu "AT+CMGS=$msg->{PDU_Len}\r";
    &ModemExpect(60, ">");
    print $cu $pdu . chr(26);
    &ModemExpect(60, "OK", "ERROR");
    if ($cu->exp_match eq "ERROR") {
        &Debug(2, "SMS Message could not be sent!");
        return 0;
    } elsif ($cu->exp_match eq "OK") {
        &Debug(2, "SMS Message sent.");
        return 1;
    }
}

sub OutSendConfirmation {
    my ($DocId, $StatusStr, $number) = @_;
#       my $file1 = &GetTempPath($SMS->{InDir}, "TMP_", "TXT");
        &Debug(1,"Starting Write the Control file...!");
        my $file1 = $SMS->{ControlFile};
        open MAIL, ">> $file1";
    print MAIL "[SMS_SEND_DETAILS]\n";
    print MAIL "From=$SMS->{InEmailFrom}\n";
        print MAIL "DocID=$DocId\n";
    print MAIL "PhoneNumber=$number\n";
    print MAIL "SMS_Status=$StatusStr\n\n\n";
#    print MAIL "From: $SMS->{InEmailFrom}\n";
#    print MAIL "Subject: DELIVERY/$StatusStr/$DocId\n\n";
#    print MAIL "$StatusStr\n";
    close MAIL;
    &Debug(1,"Write control file complete!");
#    my $file2 = &GetTempPath($SMS->{InDir}, "IN_", "TXT");
#    rename $file1, $file2;
}
    
sub SubTractionTwoDateTime {
    my ($firdate, $secdate) = @_;
    my @f1 = split(':', $firdate);
    my @f2 = split(':', $secdate);

    if ($f1[2] < $f2[2]) {
        return ($f2[2] - $f1[2]);
    }else {
        return -1;
    }

}
sub ModemExpect {
    $cu->expect(@_) or &Abort("Cannot communicate with GSM Modem! Line = ". (caller)[1]);
}

sub SIGTermProc {
    &Debug(1, "Termination signal received! Cleaning up...");
    &Kill_cu();
}

sub SIGChldProc {
    unless ($SIGCHLD_CU) {
        $SIGCHLD_CU = 1;
        return;
    }
    &Debug(1, "Exiting since child process terminated!");
    &Debug(1, "========== Megaeyes SMS program for port $port shut down ==========");
    exit 1;
}

sub Kill_cu {
    unless (kill "HUP", $cu->pid) { #This will kill child cu process
        &Debug(1, "===== Cannot send HUP signal to cu program! Exiting... =====");
        exit 1;
    }
    sleep 5;
    kill 9, $cu->pid; #This will kill parent cu process
    sleep 60; #Should die due to SIGCHLD
}

sub GetTempPath {
    my ($dir, $prefix, $postfix) = @_;
    return undef unless -d $dir;
    return "$dir/" . &GetTempName(DIR => $dir, PREFIX => $prefix, EXT => $postfix);
}

sub decode_text_UCS2 {
    my $encoded= shift;
    return undef unless $encoded;
    
    my $converter = Text::Iconv->new("gb2312", "unicode");
    $encoded = $converter->convert($encoded);

    my $len = hex substr( $encoded, 0, 2 );
    $encoded  = substr $encoded, 2;
    my $len = length($encoded);
    my $decoded="";
    while( $encoded ) {
        $decoded.=pack("U",hex(substr($encoded,0,4)));
        $encoded = substr($encoded,4);        
    }

    return $decoded, $len ;
}

sub get_unicode_length {
    my $t = shift();
    Encode::_utf8_on($t);
    return length($t);
}


sub Text2PDUFormat {
   my $textChange = shift();
   $textChange =~ s/^\s+|\s+$//g;
   my ($i,$converter,$tempText,$lenOftext,$lenOftext1,$teltext,$lenOfpdu);
   my ($j,$tempnoa,$tempnob,$tempresult,$relplacet);  
   $lenOftext1 = length($textChange);
   my $unicodecode = $textChange;
   #&Debug(2, "Old textChange is $textChange, lenoftext = $lenOftext1");   
   $converter = Text::Iconv->new("gb2312","unicode");
   $textChange = $converter->convert($textChange);
   $lenOftext = length($textChange) - 2;

   #&Debug(2, "textChange is $textChange, lenoftext = $lenOftext"); 
   for($i = 0;$i <=$lenOftext+1; $i++){
        $tempText = sprintf("%02X",ord(substr($textChange,$i)));
        $teltext .= $tempText;
    }
        $teltext =~ s/^FFFE//gi;
        $lenOfpdu = length($teltext);
    
  
  for($j = 0;$j < $lenOfpdu/4;$j++){
      $tempnoa = substr($teltext,0,2);
      $tempnob = substr($teltext,2,2);
      $tempresult .= $tempnob.$tempnoa;
      $relplacet = $tempnoa.$tempnob;
      $teltext =~ s/^$relplacet//gi;
      
   }
   #&Debug(1, "TempResult : $tempresult");
   return $tempresult, length($tempresult)/2;
}


sub Debug {
    my ($level, $str) = @_;
    my $out;
    my ($leveldbg, $levelptr);
    if (ref($level) eq "ARRAY") {
        ($leveldbg, $levelptr) = @$level;
    } else {
        ($leveldbg, $levelptr) = ($level, $level);
    }
    unless ($DEBUG < $leveldbg) {
        open DBG, ">>$LogFile";
        my $tmp = $str;
#        $tmp =~ s/\n[ \t]*/ /gs;
        my $prefix = localtime() . " <*> ";
        $tmp =~ s/^/$prefix/gm;
        $tmp =~ s/<\*>/<$leveldbg>/;
#        $out = localtime() . " <$leveldbg> $tmp\n";
        $tmp .= "\n" unless $tmp =~ /\n$/;
        print DBG "$tmp";
        close DBG;
    }
    unless ($DEBUG < $levelptr) {
        $out = localtime() . " <$levelptr> $str\n";
        print $out;
    }
}


sub GetTime {
    my @a = localtime;
    $a[4]++;
    map {$a[$_] = sprintf("%02d", $a[$_])} (0 .. 4);
    my $time = join(":", $a[2], $a[1], $a[0]);
    my $date = join("/", $a[3], $a[4], $a[5] + 1900);
    return wantarray ? ($date, $time) : "$date $time";
}


sub GetYYYYMMDDDateFormat {
    my @a = localtime;
    $a[4]++;
    map {$a[$_] = sprintf("%02d", $a[$_])} (0 .. 4);
    my $time = join(":", $a[2], $a[1], $a[0]);
    my $date = join("/", $a[5] + 1900, $a[4], $a[3]);
    return wantarray ? ($date, $time) : "$date $time";
   
}
sub QM {
    return "(" . "?," x (shift() - 1) . "?)";
}

sub GetTempName {
    my %arg = @_;
    my $prefix = $arg{PREFIX} ? $arg{PREFIX} : "";
    my $dir = $arg{DIR};
    my $ext = $arg{EXT} ? ".$arg{EXT}" : "";
    my $ret;
    do {
        $ret = $prefix . $$ . int(rand 10000);
    } until not (-f "$dir/$ret$ext");
    &Debug(2, "Unique name found: $ret");
    return $ret;
}

sub ReadIni {
    my $IniFile;
    if ($ENV{DMS_INI}) {
        $IniFile = $ENV{DMS_INI};
    } elsif (-f "/etc/smsserver.ini") {
        $IniFile = "/etc/smsserver.ini";
    } else {
        die "No smsserver.ini file found!";
    }

    my $ini;
    my $I = IniConf->new( -file => $IniFile);
    foreach my $i ($I->Sections) {
        foreach my $j ($I->Parameters($i)) {
            $ini->{$i}->{$j} = $I->val($i, $j);
        }
    }
    $LOG_DIR = ($ini->{General}->{LogDir} or "/var/log");
    return $ini;
}


sub decode_text_UCS2_ex {
  my ($t1,$t2,$t3);
  my ($i,$j);
   my $t = shift();
   my $l = length($t);
  
   my $cvt = Text::Iconv->new("gb2312","unicode");
   $t = $cvt->convert($t);
   $l = length($t) - 2;
   for($i = 0;$i <=$l+1; $i++){
        $t1 = sprintf("%02X",ord(substr($t,$i)));
        $t2 .= $t1;
    }
        $t2 =~ s/^FFFE//gi;
        $l = length($t2);
    
  
  for($j = 0;$j < $l/4; $j++){
      $t3 .= substr($t2, $j+2, 2). substr($t2, $j, 2);
   }
   return $t3, $l;
}
