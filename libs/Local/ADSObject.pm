package Local::ADSObject;
require 5.000;
require Exporter;
use DBI;
use Net::LDAPS;
use Net::LDAP;
use Net::LDAP::Search;
use Net::LDAP::Control::Paged;
use Net::LDAP::Constant qw( LDAP_CONTROL_PAGED );
use Net::LDAP::LDIF;
use Net::DNS;
use Local::AuthSrv;
use Math::BigInt;    # should do with eval instead perhaps
use Local::UsageLogger;
use Sys::Syslog;

BEGIN {
    &LogAPIUsage();
}

# Begin-Doc
# Name: Local::ADSObject
# Type: module
# Description:  Allows for create/modify/delete/reset passwords in AD
# Syntax:  use Local::ADSObject;
# End-Doc

@ISA    = qw(Exporter);
@EXPORT = qw();

my $retries = 4;    # Set this to one higher than the number of DCs.

# Last Error Message
$ErrorMsg = "no error";

#
# Flag bits for UserAccountControl field
#

my $UAC_BIT_INFO = [
    [ 0x00000001, "",                    "UF_SCRIPT" ],
    [ 0x00000002, "Account Enabled",     "Account Disabled" ],
    [ 0x00000004, "",                    "Unk4" ],
    [ 0x00000008, "",                    "Homedir Required" ],
    [ 0x00000010, "",                    "Locked Out" ],
    [ 0x00000020, "Password Required",   "Password Not Required" ],
    [ 0x00000040, "Can Change Password", "Cannot Change Password" ],
    [ 0x00000080, "", "Store PW with Reversible Encryption" ],
    [ 0x00000100, "", "Temporary Duplicate Account" ],
    [ 0x00000200, "", "Normal Account" ],
    [ 0x00000400, "", "Unk1024" ],
    [ 0x00000800, "", "Interdomain Trust Account" ],
    [ 0x00001000, "", "Workstation Trust Account" ],
    [ 0x00002000, "", "Server Trust Account" ],
    [ 0x00010000, "", "Password never expires" ],
    [ 0x00020000, "", "MNS Logon Account" ],
    [ 0x00040000, "", "Smart Card Required for Logon" ],
    [ 0x00080000, "", "Account trusted for delegation" ],
    [ 0x00100000, "", "Account cannot be delegated" ],
    [ 0x00200000, "", "Use DES enctypes" ],
    [ 0x00400000, "", "No preauth required" ],
    [ 0x00800000, "", "Password Expired" ],
];
my $UAC_DISABLED               = 0x00000002;
my $UAC_INITIALIZED            = 0x00000200;
my $UAC_NEVER_EXPIRES          = 0x00010000;
my $UAC_WORKSTATION_TRUST      = 0x00001000;
my $UAC_TRUSTED_FOR_DELEGATION = 0x00080000;
my $UAC_DES_ONLY               = 0x00200000;
my $UAC_PW_NOT_REQUIRED        = 0x00000020;
my $UAC_CANNOT_CHANGE_PW       = 0x00000040;
my $UAC_NORMAL_ACCOUNT         = $UAC_INITIALIZED | $UAC_NEVER_EXPIRES;

my $UAC_COMPUTER_ACCOUNT =
  $UAC_NEVER_EXPIRES | $UAC_WORKSTATION_TRUST | $UAC_DES_ONLY |
  $UAC_TRUSTED_FOR_DELEGATION;

my $UAC_UNIXHOST_ACCOUNT =
  $UAC_NORMAL_ACCOUNT | $UAC_TRUSTED_FOR_DELEGATION | $UAC_DES_ONLY;

#
# Flag bits for group type field
#
my $GTYPE_BIT_INFO = [
    [ 0x00000002, "", "Global Group" ],
    [ 0x00000004, "", "[Domain] Local Group" ],
    [ 0x00000008, "", "Universal Group" ],
    [ 0x80000000, "", "Security Enabled" ],
];

#
# Flag bits for instance type field
#

#
# Values account type field
#
my $ATYPE_VALS = [
    [ 0x10000000, "Security Global Group" ],
    [ 0x10000001, "Distribution Group" ],
    [ 0x20000000, "Security Local Group" ],
    [ 0x20000001, "Distribution Local Group" ],
    [ 0x30000000, "Normal Account" ],
    [ 0x30000001, "Workstation Trust" ],
    [ 0x30000002, "Interdomain Trust" ],
];

# Begin-Doc
# Name: new
# Type: function
# Description:  Binds to AD
# Syntax: $ex = new Local::ADSObject(
#		user => $user,
#		password => $pw) || die $Local:ADSObject::ErrorMsg;
# End-Doc
sub new {
    my $self          = shift;
    my $class         = ref($self) || $self;
    my %info          = @_;
    my $mode          = $info{mode} || "R";
    my $pref_pagesize = $info{pagesize} || 25;
    my $pref_debug    = $info{debug} || 0;
    my $timeout       = $info{timeout} || 60;
    my $use_gc        = $info{use_gc} || 0;
    my $domain        = $info{domain} || "umr.edu";

    &LogAPIUsage();

    my $server;

    if ( $domain eq "mst.edu" ) {
        $server = $info{server} || "mst-dc.mst.edu";
    }
    else {
        $server = $info{server} || "umr-dc.umr.edu";
        if ($use_gc) {
            $server = "umr-gc.umr.edu";
        }
    }

    $pref_debug && print "using server ($server)\n";

    my $port = $info{port} || 636;
    my $ssl;
    if ( defined( $info{ssl} ) ) {
        $ssl = $info{ssl};
    }
    else {
        $ssl = 1;
    }

    if ( defined( $info{port} ) ) {
        $port = $info{port};
    }
    else {
        if ($use_gc) {
            if ($ssl) {
                $port = 3269;
            }
            else {
                $port = 3268;
            }
        }
        else {
            if ($ssl) {
                $port = 636;
            }
            else {
                $port = 389;
            }
        }
    }

    my $user = $info{user}     || ( getpwuid($>) )[0];
    my $pw   = $info{password} || &AuthSrv_Fetch(
        user     => $user,
        instance => 'ads'
    );

    # set any object params
    my $tmp = {};

    $tmp->{"debug"}  = $pref_debug;
    $tmp->{"basedn"} = $info{basedn};
    if ( !$tmp->{"basedn"} ) {
        if ( $domain eq "mst.edu" ) {
            $tmp->{basedn} = "DC=mst,DC=edu";
        }
        elsif ( !$use_gc ) {
            $tmp->{"basedn"} = "DC=umr,DC=edu";
        }
        else {
            $tmp->{"basedn"} = "DC=edu";
        }
    }
    $tmp->{"domain"} = $domain;

    $pref_debug && print "creating ldap object\n";
    if ($ssl) {
        $tmp->{ldap} = new Net::LDAPS(
            $server,
            port    => $port,
            version => 3,
            timeout => $timeout
        );
    }
    else {
        $tmp->{ldap} = new Net::LDAP(
            $server,
            port    => $port,
            version => 3,
            timeout => $timeout
        );
    }
    if ( !$tmp->{ldap} ) {
        $pref_debug && print $@, "\n";
        return undef;
    }
    $tmp->{pagesize} = $pref_pagesize;

    my $ldap  = $tmp->{ldap};
    my $count = 0;
    my $res   = undef;
    my $bound = 0;
    while ( $count < $retries && !$bound ) {
        $res = $ldap->bind( "$user\@$domain", password => $pw );
        if ( !$res->code ) {
            $bound = 1;
            last;
        }
        $count++;
    }
    if ( !$bound ) {
        $ErrorMsg = "ldap bind failed: " . $res->error;
        return undef;
    }
    else {
        return bless $tmp, $class;
    }
}

# Begin-Doc
# Name: debug
# Type: method
# Access: public
# Description: Sets or returns current module debugging level
# Syntax: $obj->debug(1) to enable
# Syntax: $obj->debug(0) to disable
# End-Doc
sub debug {
    my $self = shift;
    if (@_) {
        $self->{debug} = shift;
    }
    else {
        return $self->{debug};
    }
}

# Begin-Doc
# Name: ldap
# Type: method
# Access: semi-private
# Description: Returns the internal ldap connection established by the object
# Returns: reference to a Net::LDAP or Net::LDAPS object
# End-Doc
sub ldap {
    my $self = shift;
    my $ldap = $self->{ldap};

    return $ldap;
}

# Begin-Doc
# Name: _GetDN
# Type: method
# Access: private
# Description: Does a search on the spn attributei for host/$hostname and returns the
# distinguishedName attribute
# Returns: distinguishedName
# End-Doc

sub _GetHostDN {
    my $self  = shift;
    my $ldap  = $self->{ldap};
    my $Dname = undef;

    my ($host) = @_;

    my $baseDN = $self->{basedn};
    my $domain = $self->{domain};

    my $srch = $ldap->search(
        base   => $baseDN,
        scope  => 'sub',
        filter => "(|(servicePrincipalName=host/$host))",
        attrs  => ['distinguishedName']
    );

    my @entries = $srch->entries;
    my $max     = $srch->count;

    foreach my $entry ( $srch->all_entries ) {
        $Dname = $entry->get_value('distinguishedName');
    }
    $self->debug && print "Dname2 is $Dname\n";

    if ( $srch->code ) {
        $ErrorMsg = "Search failed: " . $srch->error . "\n";
        return undef;
    }
    return $Dname;
}

# Begin-Doc
# Name: FindUPN
# Type: method
# Access: public
# Description: Searches for first instance found of a particular userid
# Returns: user principal name for authentication
# End-Doc

sub FindUPN {
    my $self  = shift;
    my $ldap  = $self->{ldap};
    my $Dname = undef;

    my ($SAM) = @_;
    $self->debug && print "SAM is $SAM\n";

    my $baseDN = $self->{basedn};
    $self->debug && print "baseDN = $baseDN\n";

    my $srch = $ldap->search(
        base   => $baseDN,
        scope  => 'sub',
        filter => "(|(sAMAccountName=$SAM))",
        attrs  => ['userPrincipalName']
    );

    my $entry = ( $srch->entries )[0];
    my $upn;

    if ($entry) {
        $upn = $entry->get_value('userPrincipalName');
    }
    $self->debug && print "upn is $upn\n";

    if ( $srch->code ) {
        $ErrorMsg = "Search failed: " . $srch->error . "\n";
        return undef;
    }
    return lc $upn;
}

# Begin-Doc
# Name: _GetDN
# Type: method
# Access: private
# Description: Does a search on the sAMAccountName attribute and returns the
# distinguishedName attribute
# Returns: distinguishedName
# End-Doc

sub _GetDN {
    my $self  = shift;
    my $ldap  = $self->{ldap};
    my $Dname = undef;

    my ($SAM) = @_;
    $self->debug && print "SAM is $SAM\n";

    my $baseDN = $self->{basedn};
    $self->debug && print "baseDN = $baseDN\n";

    my $domain = $self->{domain};
    $self->debug && print "domain = $domain\n";

    my $srch = $ldap->search(
        base   => $baseDN,
        scope  => 'sub',
        filter => "(|(sAMAccountName=$SAM))",
        attrs  => ['distinguishedName']
    );

    my @entries = $srch->entries;
    my $max     = $srch->count;

    foreach my $entry ( $srch->all_entries ) {
        $Dname = $entry->get_value('distinguishedName');
    }
    $self->debug && print "Dname1 is $Dname\n";

    if ( !$Dname ) {
        my $srch = $ldap->search(
            base   => $baseDN,
            scope  => 'sub',
            filter => "(|(userPrincipalName=$SAM\@" . $domain . "))",
            attrs  => ['distinguishedName']
        );

        my @entries = $srch->entries;
        my $max     = $srch->count;

        foreach my $entry ( $srch->all_entries ) {
            $Dname = $entry->get_value('distinguishedName');
        }
        $self->debug && print "Dname2 is $Dname\n";
    }

    if ( $srch->code ) {
        $ErrorMsg = "Search failed: " . $srch->error . "\n";
        return undef;
    }
    return $Dname;
}

# Begin-Doc
# Name: SetPassword
# Type: method
# Description:  Resets the ADS Password for a userid
# Syntax:  $setpw = $ex->SetPassword(
#			userid => "miner",
#			password => "engineer");
# Returns: undef is successful otherwise the error
# End-Doc
sub SetPassword {
    my $self = shift;
    my (%info) = @_;
    my ( $userid, $password, $upn, $dn, $res );
    $userid   = $info{userid}   || return "need a userid\n";
    $password = $info{password} || return "need new password\n";

    syslog( "info",
            "ADSObject SetPassword ($userid) by "
          . $ENV{REMOTE_USER}
          . " from host "
          . $ENV{REMOTE_HOST} );

    $dn = $self->_GetDN($userid);
    if ( !$dn ) {
        $self->debug && print "userid not found\n";
        $ErrorMsg = "Userid '$userid' not found. Password not set.\n";
        return $ErrorMsg;
    }

    $self->debug && print "dn is $dn\n";
    $self->debug && print "userid is $userid\n";
    $self->debug && print "password is $password\n";

    #---
    # simple string=>unicode conversion
    #---
    $pw  = $self->_MakeUnicode($password);
    $res = $self->{ldap}->modify(
        dn      => $dn,
        changes => [ replace => [ "unicodePwd" => $pw, ] ]
    );
    if ( $res->code ) {
        $ErrorMsg = "password set failed: " . $res->error;
        return $ErrorMsg;
    }

    $res = $self->_ModifyUACBits(
        userid => $userid,
        reset  => $UAC_PW_NOT_REQUIRED,
    );
    if ($res) {
        $ErrorMsg = "password set failed: " . $res;
        return $ErrorMsg;
    }

    return undef;
}

sub _gen_random_pw {
    my $pw;
    my @chars =
      split( '',
        join( "", "a" .. "z", "A" .. "Z", "0" .. "9", "-=;,./-=;,./" ) );
    my $reason;

    &LogAPIUsage();

    $pw = "";
    for ( my $i = 0 ; $i < 22 ; $i++ ) {
        my $rnd = int( rand( $#chars + 1 ) );
        $pw .= $chars[$rnd];
    }

    return $pw;
}

# Begin-Doc
# Name: CreateUser
# Type: method
# Description: Creates a user in AD...note that the userid is disabled until
# Syntax: $crtusr = $ex->ADS_CreateUser(
#			DistinguishedName => $dn,
#			SamAccountName => $samaccount,
#			DisplayName => $display,
#			UserPrincipalName => $upn)
# Returns: undef if success, else error
# End-Doc

sub CreateUser {
    my $self = shift;
    my (%info) = @_;
    my ( $dn, $samName, $dispName, $userPN, $princ );
    my $ldap = $self->{ldap};
    $dn       = $info{DistinguishedName};
    $samName  = $info{SamAccountName};
    $dispName = $info{DisplayName};
    $userPN   = $info{UserPrincipalName};
    $spn      = $info{ServicePrincipalName};
    $self->debug && print "dispName = $dispName\n";
    $self->debug && print "userPN = $userPN\n";
    $self->debug && print "samName = $samName\n";
    $self->debug && print "dn = $dn\n";

    $self->debug && print "inside create\n";
    $crtusr = $self->{ldap}->add(
        dn   => "$dn",
        attr => [
            SamAccountName    => "$samName",
            DisplayName       => "$dispName",
            UserPrincipalName => "$userPN\@umr.edu",
            objectclass => [ 'top', 'person', 'organizationalPerson', 'user' ],
            unicodePwd  => $self->_MakeUnicode( $self->_gen_random_pw() ),
            userAccountControl => 0,
        ]
    );

    if ( $crtusr->code ) {
        $self->debug && print "Create failed: " . $crtusr->error . "\n";
        $ErrorMsg = "create failed: " . $crtusr->error;
        return "Create failed: " . $crtusr->error . "\n";
    }
    else {
        $self->debug && print "create ok\n";
    }

    #
    # Now enable the user
    #
    # and make it never expire
    $res = $self->EnableAccount($samName);
    if ($res) { return $res; }

    $res = $self->_ModifyUACBits(
        userid => $samName,
        set    => $UAC_NEVER_EXPIRES,
        reset  => $UAC_PW_NOT_REQUIRED,
    );
    if ($res) { return $res; }

    return undef;
}

# Begin-Doc
# Name: CreateSecurityGroup
# Type: method
# Description: Creates a security group netgroup
# Syntax: $crtusr = $ex->CreateSecurityGroup(
#			group => $group)
# Returns: undef if success, else error
# End-Doc

sub CreateSecurityGroup {
    my $self = shift;
    my (%info) = @_;
    my ($group);
    my $ldap = $self->{ldap};
    $group = $info{group};
    my $ou = $info{ou};

    if ( !defined($ou) ) {

        if ( $group =~ /^ng-/ ) {
            $ou = "OU=NetGroups," . $self->{basedn};
        }
        else {
            return "need to specify OU";
        }
    }
    my $dn = "CN=$group,$ou";

    $self->debug && print "dn = $dn\n";

    $self->debug && print "inside create\n";
    $crtusr = $self->{ldap}->add(
        dn   => "$dn",
        attr => [
            sAMAccountName => "$group",
            name           => $group,
            objectclass    => [ 'top', 'group' ],
            groupType      => -2147483640
        ]
    );
    if ( $crtusr->code ) {
        $self->debug && print "Create failed: " . $crtusr->error . "\n";
        $ErrorMsg = "create failed: " . $crtusr->error;
        return $ErrorMsg;
    }

    return undef;
}

# Begin-Doc
# Name: DeleteUser
# Type: method
# Description: Deletes a userid from AD
# Syntax: $deluser = $ads->DeleteUser( userid => $name);
# End-Doc

sub DeleteUser {
    my $self = shift;
    my (%info) = @_;
    my ($upn);
    my $userid = $info{userid} || return "Need the userid\n";
    my $dn = $self->_GetDN($userid);
    $delusr = $self->{ldap}->delete($dn);
    if ( $delusr->code ) {
        return "delete failed: " . $delusr->error . "\n";
    }
    return undef;
}

# Begin-Doc
# Name: Delete_Unix_Host
# Type: method
# Description: Deletes a unix host principal
# Syntax: $deluser = $ads->Delete_Unix_Host( fqdn => $fqdn);
# End-Doc

# Begin-Doc
# Name: _MakeUnicode
# Type: method
# Description: simple ascii to unicode/2bytechar conversion
# Syntax: $unicode = $ads->_MakeUnicode($string);
# Access: internal
# End-Doc
sub _MakeUnicode {
    my $self = shift;
    my ( $string, $plainstring, $chr );
    $string = shift;

    #	print "string $string\n";
    $plainstring = "\"$string\"";

    #---
    # simple string=>unicode conversion
    #
    my @tmp = ();
    foreach $chr ( split( '', $plainstring ) ) {
        push( @tmp, $chr );
        push( @tmp, chr(0) );
    }
    $unistring = join( "", @tmp );

    #
    #---
    return $unistring;
    print "$unistring\n";
}

# Begin-Doc
# Name: FindProxyHost
# Type: method
# Description: Finds mailbox host for a given proxy address
# Syntax: $host = $ad->FindProxyHost($email)
# Returns: hostname if success, else error
# Comments: If address does not have a type in front of it, assumes smtp
# End-Doc

sub FindProxyHost {
    my $self = shift;
    my ($email) = @_;
    my ( $res, $homeServer );
    my $ldap = $self->{ldap};

    if ( $email !~ /^[a-z0-9\.]+:/o ) {
        $email = "smtp:$email";
    }

    $res = $self->{ldap}->search(
        base   => $self->{basedn},
        scope  => 'sub',
        filter => "(|(proxyAddresses=$email))",
        attrs  => ['msExchHomeServerName']
    );
    if ( $res->code ) {
        $self->debug && print "Search failed: " . $res->error . "\n";
        $ErrorMsg = "create failed: " . $res->error;
        return undef;
    }

    my @entries = $res->entries;
    foreach my $entry ( $res->entries ) {
        $homeServer = $entry->get_value('msExchHomeServerName');
    }

    $homeServer =~ s/.*cn=//gio;
    if ( $homeServer !~ /UMR-MAIL\d+/ ) {
        $ErrorMsg = "unknown server pattern";
        return undef;
    }

    return lc($homeServer);
}

# Begin-Doc
# Name: GetUserList
# Type: method
# Description: Returns list of all ADS userids
# Syntax: @users = $ad->GetUserList()
# Returns: Returns list of all ADS userids
# End-Doc

sub GetUserList {
    my $self = shift;
    my $ldap = $self->{ldap};
    my $page = new Net::LDAP::Control::Paged( size => $self->{pagesize} )
      || return undef;
    my @users = ();
    my $res;

    while (1) {
        $res = $self->{ldap}->search(
            base    => $self->{basedn},
            scope   => 'sub',
            filter  => "(&(sAMAccountName=*))",
            attrs   => ['sAMAccountName'],
            control => [$page],
        );
        if ( $res->code ) {
            $self->debug && print "Search failed: " . $res->error . "\n";
            $ErrorMsg = "create failed: " . $res->error;
            return undef;
        }

        foreach $entry ( $res->entries ) {
            my $sa = lc $entry->get_value('sAMAccountName');
            push( @users, $sa );
        }

        my ($resp) = $res->control(LDAP_CONTROL_PAGED) or last;

        $cookie = $resp->cookie or last;
        $page->cookie($cookie);
    }

    return @users;
}

# Begin-Doc
# Name: GetMultiCampusUserList
# Type: method
# Description: Returns list of all ADS userids
# Syntax: @users = $ad->GetMultiCampusUserList()
# Returns: Returns list of all ADS userids
# End-Doc

sub GetMultiCampusUserList {
    my $self = shift;
    my $ldap = $self->{ldap};
    my $page = new Net::LDAP::Control::Paged( size => $self->{pagesize} )
      || return undef;
    my @users = ();
    my $res;

    while (1) {
        $res = $self->{ldap}->search(
            base    => 'OU=Multi-Campus,OU=Accounts,DC=umr,DC=edu',
            scope   => 'sub',
            filter  => "(&(sAMAccountName=*))",
            attrs   => ['sAMAccountName'],
            control => [$page],
        );
        if ( $res->code ) {
            $self->debug && print "Search failed: " . $res->error . "\n";
            $ErrorMsg = "create failed: " . $res->error;
            return undef;
        }

        foreach $entry ( $res->entries ) {
            my $sa = lc $entry->get_value('sAMAccountName');
            push( @users, $sa );
        }

        my ($resp) = $res->control(LDAP_CONTROL_PAGED) or last;

        $cookie = $resp->cookie or last;
        $page->cookie($cookie);
    }

    return @users;
}

# Begin-Doc
# Name: GetMailboxUserList
# Type: method
# Description: Returns list of all ADS userids w/ exchange mailboxes
# Syntax: @users = $ad->GetMailboxUserList()
# Returns: Returns list of all ADS userids
# End-Doc

sub GetMailboxUserList {
    my $self = shift;
    my $ldap = $self->{ldap};
    my $page = new Net::LDAP::Control::Paged( size => $self->{pagesize} )
      || return undef;
    my @users = ();
    my $res;

    while (1) {
        $res = $self->{ldap}->search(
            base    => $self->{basedn},
            scope   => 'sub',
            filter  => "(&(msExchHomeServerName=*UMR*))",
            attrs   => ['sAMAccountName'],
            control => [$page],
        );
        if ( $res->code ) {
            $self->debug && print "Search failed: " . $res->error . "\n";
            $ErrorMsg = "Search failed: " . $res->error;
            return undef;
        }

        foreach $entry ( $res->entries ) {
            my $sa = lc $entry->get_value('sAMAccountName');
            push( @users, $sa );
        }

        my ($resp) = $res->control(LDAP_CONTROL_PAGED) or last;

        $cookie = $resp->cookie or last;
        $page->cookie($cookie);
    }

    return @users;
}

# Begin-Doc
# Name: GetAttributes
# Type: method
# Description: Returns all attributes associated with a userid
# Syntax: $info = $ad->GetAttributes($userid, [attributes => [attriblist], [base => "basedn"])
# Returns: hash reference, elements are the ldap keys for each attribute, values are array references
# Comments: In most cases, the array will only have a single element, in some there will be multiple elements.
# Comments: can optionally specify list of specific attributes to retrieve,
#	otherwise it retrieves everything.
# End-Doc

sub GetAttributes {
    my $self   = shift;
    my $ldap   = $self->{ldap};
    my $userid = shift;
    my ( $info, $res, @entries, $entry, $attrib );
    my %opts        = @_;
    my $whichattrib = $opts{attributes};
    my $base        = $opts{base} || $self->{basedn};

    $info = {};

    if ( !defined($userid) ) {
        $self->debug && print "Must specify userid.\n";
        $ErrorMsg = "must specify userid";
        return undef;
    }

    $self->debug && print "GetAttributes searching for $userid\n";

    if ( !defined($whichattrib) ) {
        $res = $self->{ldap}->search(
            base   => $base,
            scope  => 'sub',
            filter => "(&(sAMAccountName=$userid))",
        );
    }
    else {
        $res = $self->{ldap}->search(
            base   => $base,
            scope  => 'sub',
            filter => "(&(sAMAccountName=$userid))",
            attrs  => $whichattrib,
        );
    }
    if ( $res->code ) {
        $self->debug && print "Search failed: " . $res->error . "\n";
        $ErrorMsg = "create failed: " . $res->error;
        return undef;
    }

    @entries = $res->all_entries;
    $entry   = shift(@entries);

    if ( !defined($entry) ) {
        return undef;
    }

    foreach my $aref ( @{ $entry->{asn}->{attributes} } ) {
        my $name   = $aref->{type};
        my $values = $aref->{vals};

        if ( $name =~ /(.*);range=/o ) {
            my $aname = $1;
            $info->{$aname} = $self->_GetLargeAttribute( $entry->dn, $aname );
        }
        else {

            #$self->debug && print "got $name attribute\n";
            $info->{$name} = $values;
        }
    }

    return $info;
}

# Begin-Doc
# Name: GetDNAttributes
# Type: method
# Description: Returns all attributes associated with a dn
# Syntax: $info = $ad->GetDNAttributes($dn, [attributes => [attriblist])
# Returns: hash reference, elements are the ldap keys for each attribute, values are array references
# Comments: In most cases, the array will only have a single element, in some there will be multiple elements.
# Comments: can optionally specify list of specific attributes to retrieve,
#	otherwise it retrieves everything.
# End-Doc

sub GetDNAttributes {
    my $self = shift;
    my $ldap = $self->{ldap};
    my $dn   = shift;
    my ( $info, $res, @entries, $entry, $attrib );
    my %opts        = @_;
    my $whichattrib = $opts{attributes};

    $info = {};

    if ( !defined($dn) ) {
        $self->debug && print "Must specify dn.\n";
        $ErrorMsg = "must specify dn";
        return undef;
    }

    $self->debug && print "GetAttributes searching for $dn\n";

    if ( !defined($whichattrib) ) {
        $res = $self->{ldap}->search(
            base   => $dn,
            scope  => 'base',
            filter => "(objectClass=*)",
        );
    }
    else {
        $res = $self->{ldap}->search(
            base   => $dn,
            scope  => 'base',
            filter => "(objectClass=*)",
            attrs  => $whichattrib,
        );
    }
    if ( $res->code ) {
        $self->debug && print "Search failed: " . $res->error . "\n";
        $ErrorMsg = "create failed: " . $res->error;
        return undef;
    }

    @entries = $res->all_entries;
    $entry   = shift(@entries);

    if ( !defined($entry) ) {
        return undef;
    }

    foreach my $aref ( @{ $entry->{asn}->{attributes} } ) {
        my $name   = $aref->{type};
        my $values = $aref->{vals};

        if ( $name =~ /(.*);range=/o ) {
            my $aname = $1;
            $info->{$aname} = $self->_GetLargeAttribute( $entry->dn, $aname );
        }
        else {

            #$self->debug && print "got $name attribute\n";
            $info->{$name} = $values;
        }
    }

    return $info;
}

# Begin-Doc
# Name: GetAttributesMatch
# Type: method
# Description: Returns all attributes for userids matching a filter
# Syntax: $info = $ad->GetAttributesMatch($filter, [attributes => [attriblist], [base => $searchbase])
# Returns: ref to array of hash refs, elements are the ldap keys for each attribute, values are array references
# Comments: In most cases, the array will only have a single element, in some there will be multiple elements.
# Comments: can optionally specify list of specific attributes to retrieve,
#	otherwise it retrieves everything.
# Comments: filter is an ldap search string
# End-Doc

sub GetAttributesMatch {
    my $self   = shift;
    my $ldap   = $self->{ldap};
    my $filter = shift;
    my ( $info, $res, @entries, $entry, $attrib );
    my %opts        = @_;
    my $whichattrib = $opts{attributes};
    my $maxrecords  = $opts{maxrecords};
    my $base        = $opts{base} || $self->{basedn};
    my $page        = new Net::LDAP::Control::Paged( size => $self->{pagesize} )
      || return undef;
    my $cookie;

    $info = {};

    if ( !defined($filter) ) {
        $self->debug && print "Must specify filter.\n";
        $ErrorMsg = "must specify filter";
        return undef;
    }

    $self->debug && print "Using filter = $filter\n";

    if ( $maxrecords > 0 && $maxrecords < $self->{pagesize} ) {
        $self->debug && print "Using max records = $maxrecords\n";

        $page = new Net::LDAP::Control::Paged( size => $maxrecords )
          || return undef;
    }

    my $matches = [];
    my $count   = 0;
    while (1) {
        last if ( $maxrecords != 0 && $count >= $maxrecords );

        my %params = (
            base    => $base,
            scope   => 'sub',
            filter  => $filter,
            control => [$page],
        );

        if ( defined($whichattrib) ) {
            $params{attrs} = $whichattrib;
        }
        if ( $maxrecords > 0 ) {
            $self->debug && print "sizelimit = $maxrecords\n";
            $params{sizelimit} = $maxrecords;
        }
        $res = $self->{ldap}->search(%params);
        if ( !$res ) {
            $self->debug && print "Search failed.\n";
            $ErrorMsg = "Search failed.\n";
        }
        elsif ( $res->code ) {
            $self->debug && print "Search failed: " . $res->error . "\n";
            $ErrorMsg = "Search failed: " . $res->error;
            return undef;
        }

        foreach $entry ( $res->entries ) {
            my $info = {};
            $count++;

            $self->debug && print "got entry\n";
            foreach my $aref ( @{ $entry->{asn}->{attributes} } ) {
                my $name   = $aref->{type};
                my $values = $aref->{vals};

                if ( $name =~ /(.*);range=/o ) {
                    my $aname = $1;
                    $info->{$aname} =
                      $self->_GetLargeAttribute( $entry->dn, $aname );
                }
                else {

                    #$self->debug && print "got $name attribute\n";
                    $info->{$name} = $values;
                }
            }
            push( @$matches, $info );
        }
        my ($resp) = $res->control(LDAP_CONTROL_PAGED) or last;

        $cookie = $resp->cookie or last;
        $page->cookie($cookie);
    }
    return $matches;
}

# Begin-Doc
# Name: _WrapCB
# Type: method
# Description: Internal wrapper to reformat results to match our return style for callbacks
# Syntax: $ad->_WrapCB($callback, $searchobj, $entry, $references)
# Returns: nothing
# End-Doc
sub _WrapCB {
    my $self   = shift;
    my $cb     = shift;
    my $search = shift;    # ? what is this for
    my $entry  = shift;
    my $info   = {};

    if ( ref($entry) eq "Net::LDAP::Entry" ) {
        foreach my $aref ( @{ $entry->{asn}->{attributes} } ) {
            my $name   = $aref->{type};
            my $values = $aref->{vals};

            if ( $name =~ /(.*);range=/o ) {
                my $aname = $1;
                $info->{$aname} =
                  $self->_GetLargeAttribute( $entry->dn, $aname );
            }
            else {

                #$self->debug && print "got $name attribute\n";
                $info->{$name} = $values;
            }
        }
        &$cb($info);
    }
}

# Begin-Doc
# Name: _GetLargeAttribute
# Type: method
# Description: Returns full set of values for an attribute that may include range processing
# Syntax: $arrayref = $ad->_GetLargeAttribute($dn, $attribute)
# Returns: array ref containing values
# End-Doc
sub _GetLargeAttribute {
    my $self      = shift;
    my $dn        = shift;
    my $attr      = shift;
    my $ldap      = $self->{ldap};
    my $allvalues = [];

    $self->debug
      && print "_GetLargeAttribute called for $dn for attr $attr.\n";

    my $low  = "0";
    my $high = "*";

    my $have_more = 1;
    while ($have_more) {
        $self->debug && print "requesting $attr from $low to $high\n";
        my $res = $ldap->search(
            base   => $dn,
            scope  => 'base',
            attrs  => ["$attr;range=$low-$high"],
            filter => "(objectClass=*)",
        );

        if ( $res->code ) {
            $self->debug && print "Search failed: " . $res->error . "\n";
            $ErrorMsg = "Search failed: " . $res->error;
            return undef;
        }

        my @entries = $res->all_entries;
        my $entry   = shift(@entries);
        if ( !defined($entry) ) {

            # we're done
            $self->debug && print "didn't get any entry.\n";
            return $allvalues;
        }

        foreach my $aref ( @{ $entry->{asn}->{attributes} } ) {
            my $name   = $aref->{type};
            my $values = $aref->{vals};

            if ( $name =~ /^(.*);range=(.*?)-(.*?)$/o ) {
                my $aname    = $1;
                my $got_low  = $2;
                my $got_high = $3;

                if ( $aname ne $attr ) {
                    $self->debug
                      && print "skipping unrequested attr $aname\n";
                    next;
                }

                $self->debug
                  && print "got $aname from $got_low to $got_high\n";
                if ( ref($values) ) {
                    push( @$allvalues, @{$values} );
                }
                else {
                    push( @$allvalues, $values );
                }

                if ( $got_high ne "*" ) {
                    $low       = $got_high + 1;
                    $high      = "*";
                    $have_more = 1;
                }
                else {
                    $have_more = 0;
                }
            }
        }

        #    use Data::Dumper;
        #    print Dumper($entry);
    }

    return $allvalues;
}

# Begin-Doc
# Name: GetAttributesMatchCB
# Type: method
# Description: Returns all attributes for userids matching a filter
# Syntax: $ad->GetAttributesMatchCB($filter, $callback, [attributes => [attriblist], [base => $searchbase])
# Returns: executes $callback for each matching object, passing the $entry as the only argument
# Comments: filter is an ldap search string
# Comments: callback is a subroutine reference
# End-Doc
sub GetAttributesMatchCB {
    my $self     = shift;
    my $ldap     = $self->{ldap};
    my $filter   = shift;
    my $callback = shift;
    my ( $info, $res, @entries, $entry, $attrib );
    my %opts        = @_;
    my $whichattrib = $opts{attributes};
    my $maxrecords  = $opts{maxrecords};
    my $base        = $opts{base} || $self->{basedn};
    my $page        = new Net::LDAP::Control::Paged( size => $self->{pagesize} )
      || return undef;
    my $cookie;

    $info = {};

    if ( !defined($filter) ) {
        $self->debug && print "Must specify filter.\n";
        $ErrorMsg = "must specify filter";
        return undef;
    }

    $self->debug && print "Using filter = $filter\n";

    if ( $maxrecords > 0 && $maxrecords < $self->{pagesize} ) {
        $self->debug && print "Using max records = $maxrecords\n";

        $page = new Net::LDAP::Control::Paged( size => $maxrecords )
          || return undef;
    }

    my $count = 0;
    while (1) {
        last if ( $maxrecords != 0 && $count >= $maxrecords );

        my %params = (
            base     => $base,
            scope    => 'sub',
            filter   => $filter,
            control  => [$page],
            callback => sub { $self->_WrapCB( $callback, @_ ); },
        );

        if ( defined($whichattrib) ) {
            $params{attrs} = $whichattrib;
        }
        if ( $maxrecords > 0 ) {
            $self->debug && print "sizelimit = $maxrecords\n";
            $params{sizelimit} = $maxrecords;
        }
        $res = $self->{ldap}->search(%params);
        if ( !$res ) {
            $self->debug && print "Search failed.\n";
            $ErrorMsg = "Search failed.\n";
        }
        elsif ( $res->code ) {
            $self->debug && print "Search failed: " . $res->error . "\n";
            $ErrorMsg = "Search failed: " . $res->error;
            return undef;
        }

        my ($resp) = $res->control(LDAP_CONTROL_PAGED) or last;

        $cookie = $resp->cookie or last;
        $page->cookie($cookie);
    }
    return;
}

# Begin-Doc
# Name: SetAttributes
# Type: method
# Description:  Sets a list of attributes for a userid
# Syntax:  $res = $ex->SetAttributes(
#			userid => "miner",
#			[replace => $info],
#			[add => $info],
#			[delete => $info],
#        );
# Returns: undef is successful otherwise the error
# Comments: $info should be array ref containing [ attrib => val, ... ]
# values should either be scalars, or should be references to arrays of scalars
# For backwards compatability, "attributes" can be used instead of "replace".
# End-Doc
sub SetAttributes {
    my $self = shift;
    my (%info) = @_;
    my ( $userid, $changes, $upn, $dn );

    $userid = $info{userid} || return "need a userid\n";
    my $replace = $info{replace} || $info{attributes};
    my $add     = $info{add};
    my $delete  = $info{delete};

    if ( !$replace && !$add && !$delete ) {
        return "need list of attributes to change\n";
    }

    $dn = $self->_GetDN($userid);
    $self->debug && print "dn is $dn\n";
    $self->debug && print "userid is $userid\n";

    my @parms = ();
    if ($replace) {
        push( @parms, replace => $replace );
    }
    if ($add) {
        push( @parms, add => $add );
    }
    if ($delete) {
        push( @parms, delete => $delete );
    }

    $res = $self->{ldap}->modify(
        dn      => $dn,
        changes => \@parms
    );

    if ( $res->code ) {
        $ErrorMsg = "attribute set failed: " . $res->error;
        return "attribute set failed: " . $res->error . "\n";
    }
    return undef;
}

# Begin-Doc
# Name: ConvertTime
# Description: Converts a ADS FileTime value to unix timestamp
# Syntax: $timestamp = $ads->ConvertTime($value);
# End-Doc
sub ConvertTime {
    my $self = shift;
    my $time = shift;
    my ( $secs, $nsecs );

    # convert from 100-nanosecond intervals to 1-sec intervals
    $nsecs = new Math::BigInt $time;
    $secs  = new Math::BigInt $nsecs->bdiv(10_000_000);

    # subtract base (seconds from 1601 to 1970)
    $secs = $secs->bsub("11644473600");

    return int($secs);
}

# Begin-Doc
# Name: DumpLDIF
# Type: method
# Description: Dumps ldap info to an LDIF format file
# Syntax: $ad->DumpLDIF($fh, %options)
# Comments: Don't use this yet... Options will eventually allow specifying list of
# attributes, and a different filter string, etc.
# End-Doc

sub DumpLDIF {
    my $self = shift;
    my $ldap = $self->{ldap};
    my $page = new Net::LDAP::Control::Paged( size => $self->{pagesize} )
      || return undef;
    my $fh      = shift;
    my %options = @_;
    my $res;
    my $count;

    my $ldif = Net::LDAP::LDIF->new( $fh, "w", onerror => 'undef' );

    # Don't wrap
    $ldif->{wrap} = 0;

    $count = 0;
    while (1) {
        my %params = (
            base    => $self->{basedn},
            scope   => 'sub',
            control => [$page],
        );
        if ( $options{filter} ) {
            $params{filter} = $options{filter};
        }
        else {
            $params{filter} = "(&(distinguishedName=*))";
        }
        if ( $options{attrs} ) {
            $params{attrs} = $options{attrs};
        }
        $res = $self->{ldap}->search(%params);

        if ( $res->code ) {
            $self->debug && print "Search failed: " . $res->error . "\n";
            $ErrorMsg = "Search failed: " . $res->error;
            return undef;
        }

        foreach $entry ( $res->entries ) {
            my $dn = $entry->get_value(distinguishedName);
            $ldif->write_entry($entry);
            $count++;
            if ( $count % 50 == 0 ) {
                print $count, "\n";
            }
        }

        my ($resp) = $res->control(LDAP_CONTROL_PAGED) or last;

        $cookie = $resp->cookie or last;
        $page->cookie($cookie);
    }

    $ldif->done;
}

# Begin-Doc
# Name: CheckPassword
# Type: method
# Description: Attempts to validate an ADS password
# Syntax: $res = $ad->CheckPassword($userid, $password, $domain)
# Comments: Actually attempts to bind to ADS with that user and password, and returns
# non-zero if it cannot.
# End-Doc
sub CheckPassword {
    my $self = shift;
    my ( $userid, $password, $domain ) = @_;
    my $tmpad;

    if ( !$userid || !$password ) {
        return 1;
    }

    if ( !$domain ) {
        $domain = $self->{domain};
    }

    $tmpad = new UMR::SysProg::ADSObject(
        user     => $userid,
        password => $password,
        domain   => $domain,
    );

    if ($tmpad) {
        return 0;
    }
    else {
        return 1;
    }
}

# Begin-Doc
# Name: EnableAccount
# Type: method
# Description: Enables user account
# Syntax:  $res = $ex->EnableAccount($userid)
# Returns: undef if successful otherwise the error
# Access: public
# End-Doc
sub EnableAccount {
    my $self   = shift;
    my $userid = shift;

    return "invalid userid" if ( !defined($userid) );
    return $self->_ModifyUACBits(
        userid => $userid,
        set    => $UAC_INITIALIZED,
        reset  => $UAC_DISABLED
    );
}

# Begin-Doc
# Name: DisableAccount
# Type: method
# Description: Disables user account
# Syntax:  $res = $ex->DisablesAccount($userid)
# Returns: undef if successful otherwise the error
# Access: public
# End-Doc
sub DisableAccount {
    my $self   = shift;
    my $userid = shift;

    return "invalid userid" if ( !defined($userid) );
    return $self->_ModifyUACBits(
        userid => $userid,
        set    => $UAC_DISABLED
    );
}

# Begin-Doc
# Name: GetUserAccountControl
# Description: Fetches the contents of the userAccountControl attribute for a user
# Syntax: $res = $ex->GetUserAccountControl($userid);
# Returns: integer with contents of attribute
# End-Doc
sub GetUserAccountControl {
    my $self = shift;
    my $userid = shift || return "must specify userid";

    my $info =
      $self->GetAttributes( $userid, attributes => [userAccountControl] );
    if ( defined($info) ) {
        my ($uac) = @{ $info->{userAccountControl} };
        return int($uac);
    }
    return undef;
}

# Begin-Doc
# Name: ParseUserAccountControl
# Description: Explains contents of UAC bits
# Syntax: @info = $ex->ParseUserAccountControl($uac);
# Returns: array of strings explaining bits that are set and cleared
# End-Doc
sub ParseUserAccountControl {
    my $self = shift;
    my $uac  = shift;
    my @res  = ();

    foreach my $bitref (@$UAC_BIT_INFO) {
        my ( $bit, $ifno, $ifyes ) = @{$bitref};
        if ( ( $uac & $bit ) && $ifyes ne "" ) {
            push( @res, $ifyes );
        }
        elsif ( !( $uac & $bit ) && $ifno ne "" ) {
            push( @res, $ifno );
        }
    }

    return @res;
}

# Begin-Doc
# Name: HexSIDToText
# Description: Parses a sid in hex form into text form
# Syntax: $sid = $ex->SIDToText($value);
# End-Doc
sub HexSIDToText {
    my $self   = shift;
    my $sidhex = uc shift;
    $sidhex =~ tr/A-F0-9//cd;

    my $res;

    if ( $sidhex =~ m/^(..)(..)(............)(.*)/go ) {
        my @elem;
        my $rev    = $1;
        my $dashes = $2;
        push( @elem, "S" );
        push( @elem, hex($rev) );
        push( @elem, hex($3) );

        my $rest = $4;

        while ( $rest =~ /(..)(..)(..)(..)/g ) {
            my $val = join( "", $4, $3, $2, $1 );
            push( @elem, hex($val) );
        }

        $res = join( "-", @elem );
    }

    return $res;
}

# Begin-Doc
# Name: ParseGroupType
# Description: Explains contents of GroupType bits
# Syntax: @info = $ex->ParseGroupType($gt);
# Returns: array of strings explaining bits that are set and cleared
# End-Doc
sub ParseGroupType {
    my $self = shift;
    my $uac  = shift;
    my @res  = ();

    foreach my $bitref (@$GTYPE_BIT_INFO) {
        my ( $bit, $ifno, $ifyes ) = @{$bitref};
        if ( ( $uac & $bit ) && $ifyes ne "" ) {
            push( @res, $ifyes );
        }
        elsif ( !( $uac & $bit ) && $ifno ne "" ) {
            push( @res, $ifno );
        }
    }

    return @res;
}

# Begin-Doc
# Name: ParseAccountType
# Description: Explains contents of SAMAccountType bits
# Syntax: @info = $ex->ParseAccountType($gt);
# Returns: array of strings explaining bits that are set and cleared
# End-Doc
sub ParseAccountType {
    my $self = shift;
    my $sat  = shift;
    my @res  = ();

    foreach my $valref (@$ATYPE_VALS) {
        my ( $val, $label ) = @{$valref};
        if ( $sat == $val ) {
            return $label;
        }
    }

    return "Unknown";
}

# Begin-Doc
# Name: ParseProtocolSettings
# Description: Explains contents of protocolSettings field
# Syntax: @info = $ex->ParseProtocolSettings($val)
# Returns: array of strings explaining settings
# End-Doc
sub ParseProtocolSettings {
    my $self = shift;
    my $ps   = shift;
    my @res  = ();

    #	foreach my $byte ( split('', $ps) )
    #	{
    #                my $ch = unpack( "C", $byte );
    #		push(@res, "<BR>[". sprintf("%.2X", $ch)."/$ch] " . chr($ch));
    #	}

    my ( $type, @subfields ) = split( /\xC2\xA7/, $ps );
    if ( $type eq "POP3" ) {
        my ( $enable, $defaults, $mime, $charset, $richtext, @others ) =
          @subfields;

        if   ( $enable == 1 ) { push( @res, "POP3-Enabled" ); }
        else                  { push( @res, "POP3-Disabled" ); }

        if   ( $defaults == 1 ) { push( @res, "POP3-Use Server Defaults" ); }
        else                    { push( @res, "POP3-No Server Defaults" ); }

        if    ( $mime == 0 ) { push( @res, "POP3-MIME w/ Text and HTML" ); }
        elsif ( $mime == 1 ) { push( @res, "POP3-MIME w/ Text Only" ); }
        elsif ( $mime == 2 ) {
            push( @res, "POP3-UUEncode Enabled" );
            push( @res, "POP3-BinHex Enabled" );
        }
        elsif ( $mime == 3 ) { push( @res, "POP3-UUEncode Enabled" ); }
        elsif ( $mime == 4 ) { push( @res, "POP3-MIME w/ HTML Only" ); }

        push( @res, "POP3-Default Charset($charset)" );

        if   ( $richtext == 0 ) { push( @res, "POP3-RichText Disabled" ); }
        else                    { push( @res, "POP3-RichText Enabled" ); }
    }
    elsif ( $type eq "HTTP" ) {
        my ( $enable, $defaults, @others ) = @subfields;

        if   ( $enable == 1 ) { push( @res, "HTTP-Enabled" ); }
        else                  { push( @res, "HTTP-Disabled" ); }

        if   ( $defaults == 1 ) { push( @res, "HTTP-Use Server Defaults" ); }
        else                    { push( @res, "HTTP-No Server Defaults" ); }
    }
    elsif ( $type eq "IMAP4" ) {
        my ( $enable, $defaults, $mime, $charset, @others ) = @subfields;

        if   ( $enable == 1 ) { push( @res, "IMAP4-Enabled" ); }
        else                  { push( @res, "IMAP4-Disabled" ); }

        if   ( $defaults == 1 ) { push( @res, "IMAP4-Use Server Defaults" ); }
        else                    { push( @res, "IMAP4-No Server Defaults" ); }

        if    ( $mime == 0 ) { push( @res, "IMAP4-MIME w/ Text and HTML" ); }
        elsif ( $mime == 1 ) { push( @res, "IMAP4-MIME w/ Text Only" ); }
        elsif ( $mime == 2 ) {
            push( @res, "IMAP4-UUEncode Enabled" );
            push( @res, "IMAP4-BinHex Enabled" );
        }
        elsif ( $mime == 3 ) { push( @res, "IMAP4-UUEncode Enabled" ); }
        elsif ( $mime == 4 ) { push( @res, "IMAP4-MIME w/ HTML Only" ); }

        push( @res, "IMAP4-Default Charset($charset)" );
    }

    if ( $#others >= 0 ) {
        push( @res, "ILS Settings Present" );
    }

    return @res;
}

# Begin-Doc
# Name: _ModifyUACBits
# Type: method
# Description: Sets some userAccountControl bits for a userid, if set and reset
# overlap, the reset takes precedence.
# Syntax:  $res = $ex->Set_userAccountControl(
#			userid => "userid",
#			[set => $bits,]
#			[reset => $bits]);
# Returns: undef if successful otherwise the error
# Access: private
# End-Doc
sub _ModifyUACBits {
    my $self    = shift;
    my %opts    = @_;
    my $userid  = $opts{userid} || return "must specify userid";
    my $set     = int( $opts{set} );
    my $reset   = int( $opts{reset} );
    my $old_uac = $self->GetUserAccountControl($userid);
    my $new_uac = $old_uac;
    my $debug   = $self->debug;

    if ( !$old_uac ) {
        print "Couldn't retrieve old userAccountControl value.\n";
    }

    $debug && print "old uac = $old_uac\n";

    $debug && print join( "\n", $self->ParseUserAccountControl($old_uac) ),
      "\n";

    #	$debug && printf "\t%.8X/%d | %.8X/%d == %.8X/%d\n",
    #		$new_uac, $new_uac, $set, $set,
    #		$new_uac | $set, $new_uac | $set;
    $new_uac = $new_uac | $set;

    # Clear bits that should be cleared
    #	$debug && printf "\t%.8X/%d & ~%.8X/%d == %.8X/%d\n",
    #		$new_uac, $new_uac, $reset, $reset,
    #		$new_uac & ~$reset, $new_uac & ~$reset;

    $new_uac = ( $new_uac & ~$reset ) & 0xFFFFFFFF;

    # Add in bits that should be set
    $debug && print "new uac = $new_uac\n";
    $debug && print join( "\n", $self->ParseUserAccountControl($new_uac) ),
      "\n";

    my $res = $self->SetAttributes(
        userid     => $userid,
        attributes => [ userAccountControl => int($new_uac), ],
    );

    my $changed_uac = $self->GetUserAccountControl($userid);
    $debug && print "changed uac = $changed_uac\n";
    $debug
      && print join( "\n", $self->ParseUserAccountControl($changed_uac) ),
      "\n";

    return $res;
}

# Begin-Doc
# Name: MoveUser
# Type: method
# Description:  Moves a user object from one container or OU to another
# Syntax:  $moveuser = $ex->MoveUser( userid => "miner", dn => "cn=Miner\, Joe,cn=Users,dc=umr,dc=edu", target => "OU=CIS,OU=Accounts,DC=umr,DC=edu");
# Pass target is required and either userid or dn is required.
# Returns: undef is successful otherwise the error
# End-Doc
sub MoveUser {
    my $self = shift;
    my %info = @_;

    my $debug = $self->debug();
    my $ldap  = $self->{ldap};

    my $userid = $info{userid};
    my $dn =
         $info{dn}
      || $self->_GetDN($userid)
      || return "need a dn or userid";
    my $target = $info{target} || return "need target OU\n";

    my $tmpres = $ldap->search(
        base   => $dn,
        scope  => 'base',
        filter => "(objectclass=*)",
    );
    if ( $tmpres->code ) {
        $self->debug && print "Search failed: " . $res->error . "\n";
        $ErrorMsg = "create failed: " . $res->error;
        return $ErrorMsg;
    }

    my @entries = $tmpres->all_entries;
    my $entry   = shift(@entries);

    $cn = $entry->get_value('cn');
    if ( !$cn ) {
        $ErrorMsg = "failed to get cn for $dn.\n";
        $debug && print "Failed to get cn for $dn.\n";
        return "Failed to get cn for $dn.\n";
    }
    $debug && print "cn = $cn\n";

    $debug && print "dn is $dn\n";
    $debug && print "userid is $userid\n";
    $debug && print "Target OU is $target\n";

    # The new cn needs to have commas encoded to function properly.
    $cn =~ s/,/\\,/gio;

    $move = $ldap->modrdn(
        $dn,
        newrdn       => 'cn=' . $cn,
        newsuperior  => $target,
        deleteoldrdn => 1
    );

    if ( $move->code ) {
        $ErrorMsg = "move failed: " . $move->error;
        return $ErrorMsg;
    }
    return undef;
}

1;
