#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use JSON::PP;

# ─────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────
my $PORT        = 6400;
my $MAX_CLIENTS = 10;
my $BUFFER_SIZE = 1024;
my $USER_DB     = './users.json';
my $MSG_DB      = './messages.json';
my $MSG_MAX_AGE = 7;   # days — messages older than this are purged

# ─────────────────────────────────────────────
# PETSCII <-> ASCII Translation Tables
# ─────────────────────────────────────────────
my @PETSCII_TO_ASCII = map { ord('?') } 0..255;
for my $c (0x20 .. 0x3F) { $PETSCII_TO_ASCII[$c] = $c; }
for my $c (0x41 .. 0x5A) { $PETSCII_TO_ASCII[$c] = $c; }
for my $c (0x61 .. 0x7A) { $PETSCII_TO_ASCII[$c] = $c - 0x20; }
for my $c (0xC1 .. 0xDA) { $PETSCII_TO_ASCII[$c] = $c - 0x80 + 0x20; }
$PETSCII_TO_ASCII[0x0D] = 0x0A;
$PETSCII_TO_ASCII[0x0A] = 0x0D;
$PETSCII_TO_ASCII[0x14] = 0x7F;
$PETSCII_TO_ASCII[0x20] = 0x20;

my %PETSCII_STRIP = map { $_ => 1 } (
    0x05, 0x1C, 0x1E, 0x1F, 0x81, 0x90, 0x9B .. 0x9F,
    0x11, 0x91, 0x9D, 0x1D, 0x13, 0x93, 0x01, 0x08,
    0x09, 0x0F, 0x12, 0x92,
);

my @ASCII_TO_PETSCII = map { ord('?') } 0..255;
for my $c (0x20 .. 0x3F) { $ASCII_TO_PETSCII[$c] = $c; }
for my $c (0x41 .. 0x5A) { $ASCII_TO_PETSCII[$c] = $c; }
for my $c (0x61 .. 0x7A) { $ASCII_TO_PETSCII[$c] = $c + 0x80 - 0x20; }
$ASCII_TO_PETSCII[0x0A] = 0x0D;
$ASCII_TO_PETSCII[0x0D] = 0x0D;
$ASCII_TO_PETSCII[0x7F] = 0x14;
$ASCII_TO_PETSCII[0x08] = 0x14;
$ASCII_TO_PETSCII[0x20] = 0x20;

# ─────────────────────────────────────────────
# PETSCII Color / Screen Control Bytes
# ─────────────────────────────────────────────
use constant {
    PETSCII_CLR    => "\x93",
    PETSCII_WHITE  => "\x05",
    PETSCII_CYAN   => "\x9F",
    PETSCII_YELLOW => "\x9E",
    PETSCII_GREEN  => "\x1E",
    PETSCII_RED    => "\x1C",
    PETSCII_RVS_ON => "\x12",
    PETSCII_RVS_OFF=> "\x92",
};

my $NL = "\r";   # C64 only needs CR — \n causes double spacing

# ─────────────────────────────────────────────
# Translation Subroutines
# ─────────────────────────────────────────────
sub petscii_to_ascii {
    my ($data) = @_;
    my $out = '';
    for my $byte (unpack('C*', $data)) {
        next if $PETSCII_STRIP{$byte};
        my $mapped = $PETSCII_TO_ASCII[$byte];
        $out .= chr($mapped) if $mapped != ord('?') || $byte == ord('?');
    }
    return $out;
}

sub ascii_to_petscii {
    my ($data) = @_;
    my $out = '';
    for my $byte (unpack('C*', $data)) {
        $out .= chr($ASCII_TO_PETSCII[$byte]);
    }
    return $out;
}

sub send_raw   { my ($fh, $d) = @_; $fh->send($d); }
sub send_ascii { my ($fh, $t) = @_; $fh->send(ascii_to_petscii($t)); }
sub divider    { ascii_to_petscii("-" x 38 . $NL) }
sub thin_div   { ascii_to_petscii("." x 38 . $NL) }

# ─────────────────────────────────────────────
# User Database
# ─────────────────────────────────────────────
sub load_users {
    return {} unless -f $USER_DB;
    open(my $fh, '<', $USER_DB) or return {};
    local $/; my $json = <$fh>; close $fh;
    return eval { decode_json($json) } // {};
}

sub save_users {
    my ($u) = @_;
    open(my $fh, '>', $USER_DB) or die "Cannot write $USER_DB: $!";
    print $fh encode_json($u); close $fh;
}

sub user_exists    { my ($u) = @_; return exists load_users()->{lc $u}; }
sub check_password { my ($u,$p) = @_; my $db = load_users(); return ($db->{lc $u} && $db->{lc $u}{password} eq $p); }
sub get_user       { my ($u) = @_; return load_users()->{lc $u}; }

sub create_user {
    my ($u, $p) = @_;
    my $db = load_users();
    $db->{lc $u} = { password=>$p, created=>scalar localtime, last_login=>'', login_count=>0 };
    save_users($db);
}

sub update_login {
    my ($u) = @_;
    my $db = load_users();
    return unless $db->{lc $u};
    $db->{lc $u}{last_login} = scalar localtime;
    $db->{lc $u}{login_count}++;
    save_users($db);
}

# ─────────────────────────────────────────────
# Message Database
# ─────────────────────────────────────────────
sub load_messages {
    return [] unless -f $MSG_DB;
    open(my $fh, '<', $MSG_DB) or return [];
    local $/; my $json = <$fh>; close $fh;
    return eval { decode_json($json) } // [];
}

sub save_message {
    my ($username, $text) = @_;
    my $msgs = load_messages();
    push @$msgs, { from=>$username, date=>scalar localtime, epoch=>time(), text=>$text };
    open(my $fh, '>', $MSG_DB) or return;
    print $fh encode_json($msgs); close $fh;
    print "[MSG] Saved from $username\n";
}

sub purge_old_messages {
    my $msgs    = load_messages();
    my $cutoff  = time() - ($MSG_MAX_AGE * 86400);
    my $before  = scalar @$msgs;
    # Messages saved before epoch field existed default to 0 (kept)
    my @kept    = grep { ($_->{epoch} // 0) >= $cutoff || ($_->{epoch} // 0) == 0 } @$msgs;
    my $removed = $before - scalar @kept;
    if ($removed > 0) {
        open(my $fh, '>', $MSG_DB) or return;
        print $fh encode_json(\@kept); close $fh;
        print "[MSG] Purged $removed message(s) older than $MSG_MAX_AGE days\n";
    }
}

# ─────────────────────────────────────────────
# State Constants
# ─────────────────────────────────────────────
use constant {
    STATE_WELCOME     => 'welcome',
    STATE_LOGIN_USER  => 'login_user',
    STATE_LOGIN_PASS  => 'login_pass',
    STATE_REG_USER    => 'reg_user',
    STATE_REG_PASS    => 'reg_pass',
    STATE_REG_CONFIRM => 'reg_confirm',
    STATE_MAIN_MENU   => 'main_menu',
    STATE_MSG_WRITE   => 'msg_write',
    STATE_MSG_READ    => 'msg_read',
    STATE_GAMES_MENU  => 'games_menu',
    STATE_DICE        => 'dice',
};

# ─────────────────────────────────────────────
# Screen Builders
# ─────────────────────────────────────────────
sub send_welcome_screen {
    my ($fh) = @_;
    send_raw($fh,
        PETSCII_CLR .
        PETSCII_CYAN   . ascii_to_petscii("**************************************$NL") .
        PETSCII_YELLOW . ascii_to_petscii("*   COMMODORE 64 TERMINAL SERVER     *$NL") .
                         ascii_to_petscii("*         PETSCII BBS v1.0           *$NL") .
        PETSCII_CYAN   . ascii_to_petscii("**************************************$NL") .
        PETSCII_WHITE  . ascii_to_petscii("${NL}WELCOME! PLEASE IDENTIFY YOURSELF.$NL$NL") .
        PETSCII_GREEN  . ascii_to_petscii("  [1] LOGIN AS EXISTING USER$NL") .
                         ascii_to_petscii("  [2] REGISTER AS NEW USER$NL") .
                         ascii_to_petscii("  [Q] QUIT$NL") .
        PETSCII_WHITE  . ascii_to_petscii("${NL}ENTER CHOICE: ")
    );
}

sub send_main_menu {
    my ($fh, $username, $user) = @_;
    my $logins = $user->{login_count} // 0;
    my $last   = $user->{last_login}  || 'FIRST TIME!';
    my $msgs   = scalar @{ load_messages() };
    send_raw($fh,
        PETSCII_CLR .
        PETSCII_CYAN   . divider() .
        PETSCII_YELLOW . ascii_to_petscii("  WELCOME BACK, " . uc($username) . "!$NL") .
        PETSCII_CYAN   . divider() .
        PETSCII_WHITE  . ascii_to_petscii("  LOGINS  : $logins$NL") .
                         ascii_to_petscii("  LAST ON : $last$NL") .
        PETSCII_CYAN   . divider() .
        PETSCII_YELLOW . ascii_to_petscii("  -- TERMINAL --$NL") .
        PETSCII_GREEN  . ascii_to_petscii("  [1] SERVER TIME & DATE$NL") .
                         ascii_to_petscii("  [2] WHO IS ONLINE$NL") .
        PETSCII_CYAN   . thin_div() .
        PETSCII_YELLOW . ascii_to_petscii("  -- MESSAGES ($msgs POSTED) --$NL") .
        PETSCII_GREEN  . ascii_to_petscii("  [3] READ MESSAGES$NL") .
                         ascii_to_petscii("  [4] LEAVE A MESSAGE$NL") .
        PETSCII_CYAN   . thin_div() .
        PETSCII_YELLOW . ascii_to_petscii("  -- GAMES --$NL") .
        PETSCII_GREEN  . ascii_to_petscii("  [5] GAME ROOM$NL") .
        PETSCII_CYAN   . divider() .
        PETSCII_WHITE  . ascii_to_petscii("  [Q] LOGOUT$NL$NL") .
                         ascii_to_petscii("ENTER CHOICE: ")
    );
}

sub send_games_menu {
    my ($fh) = @_;
    send_raw($fh,
        PETSCII_CLR .
        PETSCII_CYAN   . divider() .
        PETSCII_YELLOW . ascii_to_petscii("  ** GAME ROOM **$NL") .
        PETSCII_CYAN   . divider() .
        PETSCII_GREEN  . ascii_to_petscii("  [1] DICE HIGH/LOW$NL") .
        PETSCII_WHITE  . ascii_to_petscii("  [B] BACK TO MAIN MENU$NL$NL") .
                         ascii_to_petscii("ENTER CHOICE: ")
    );
}

sub send_dice_screen {
    my ($fh, $st) = @_;
    my ($wins,$losses,$score) = ($st->{dice_wins}//0, $st->{dice_losses}//0, $st->{dice_score}//100);
    send_raw($fh,
        PETSCII_CLR .
        PETSCII_CYAN   . divider() .
        PETSCII_YELLOW . ascii_to_petscii("  ** DICE HIGH/LOW **$NL") .
        PETSCII_CYAN   . divider() .
        PETSCII_WHITE  . ascii_to_petscii("  TWO DICE ARE ROLLED. GUESS IF THE$NL") .
                         ascii_to_petscii("  TOTAL WILL BE HIGH (8-12) OR LOW$NL") .
                         ascii_to_petscii("  (2-6) OR SEVEN (7).$NL") .
        PETSCII_CYAN   . thin_div() .
        PETSCII_YELLOW . ascii_to_petscii("  SCORE : $score$NL") .
                         ascii_to_petscii("  WINS  : $wins   LOSSES: $losses$NL") .
        PETSCII_CYAN   . thin_div() .
        PETSCII_GREEN  . ascii_to_petscii("  [H] HIGH  (8-12) PAYS 1:1$NL") .
                         ascii_to_petscii("  [L] LOW   (2-6)  PAYS 1:1$NL") .
                         ascii_to_petscii("  [S] SEVEN (7)    PAYS 4:1$NL") .
        PETSCII_WHITE  . ascii_to_petscii("  [B] BACK TO GAME ROOM$NL$NL") .
                         ascii_to_petscii("BET AMOUNT + CHOICE (E.G. 10H): ")
    );
}

# ─────────────────────────────────────────────
# Server Setup
# ─────────────────────────────────────────────
my $server = IO::Socket::INET->new(
    LocalPort => $PORT,
    Type      => SOCK_STREAM,
    Reuse     => 1,
    Listen    => $MAX_CLIENTS,
) or die "Cannot create server socket on port $PORT: $!\n";

$server->blocking(0);
my $select = IO::Select->new($server);
my %clients;

$SIG{PIPE} = 'IGNORE';

purge_old_messages();

print "C64 PETSCII Terminal Server listening on port $PORT\n";

# ─────────────────────────────────────────────
# Main Event Loop
# ─────────────────────────────────────────────
while (1) {
    my @ready = $select->can_read(0.1);
    for my $fh (@ready) {

        if ($fh == $server) {
            my $client = $server->accept(); next unless $client;
            $select->add($client);
            my $addr = $client->peerhost . ':' . $client->peerport;
            $clients{$client} = {
                addr        => $addr,
                state       => STATE_WELCOME,
                linebuf     => '',
                username    => '',
                reg_user    => '',
                reg_pass    => '',
                dice_score  => 100,
                dice_wins   => 0,
                dice_losses => 0,
                dice_bet    => 10,
            };
            print "[+] Connected: $addr\n";
            send_welcome_screen($client);

        } else {
            my $data = '';
            my $bytes = $fh->recv($data, $BUFFER_SIZE);
            if (!defined $bytes || length($data) == 0) {
                _disconnect($fh, $select); next;
            }

            my $ascii = petscii_to_ascii($data);
            next unless length($ascii);
            my $st = $clients{$fh};

            # Echo keystrokes (suppress during password states)
            if ($st->{state} ne STATE_LOGIN_PASS &&
                $st->{state} ne STATE_REG_PASS   &&
                $st->{state} ne STATE_REG_CONFIRM) {
                $fh->send($data);
            }

            $st->{linebuf} .= $ascii;
            while ($st->{linebuf} =~ s/^([^\n]*)\n//) {
                my $line = $1; $line =~ s/\r//g; $line =~ s/^\s+|\s+$//g;
                handle_state($fh, $select, $st, $line);
                last unless exists $clients{$fh};
            }
        }
    }
}

# ─────────────────────────────────────────────
# State Machine
# ─────────────────────────────────────────────
sub handle_state {
    my ($fh, $select, $st, $line) = @_;
    my $state = $st->{state};

    # ── Welcome ───────────────────────────────
    if ($state eq STATE_WELCOME) {
        my $ch = uc($line);
        if    ($ch eq '1') { $st->{state} = STATE_LOGIN_USER; _send_login_prompt($fh); }
        elsif ($ch eq '2') { $st->{state} = STATE_REG_USER;   _send_reg_prompt($fh); }
        elsif ($ch eq 'Q') { send_ascii($fh, "${NL}GOODBYE!$NL"); _disconnect($fh, $select); }
        else { send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}INVALID CHOICE.$NL") .
                             PETSCII_WHITE . ascii_to_petscii("ENTER CHOICE: ")); }

    # ── Login: username ───────────────────────
    } elsif ($state eq STATE_LOGIN_USER) {
        return send_ascii($fh, "${NL}USERNAME: ") if $line eq '';
        $st->{username} = lc($line);
        if (!user_exists($st->{username})) {
            send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}USER NOT FOUND.$NL") .
                          PETSCII_WHITE . ascii_to_petscii("${NL}USERNAME: "));
            $st->{username} = '';
        } else {
            $st->{state} = STATE_LOGIN_PASS;
            send_ascii($fh, "${NL}PASSWORD: ");
        }

    # ── Login: password ───────────────────────
    } elsif ($state eq STATE_LOGIN_PASS) {
        if (check_password($st->{username}, $line)) {
            update_login($st->{username});
            purge_old_messages();
            $st->{state} = STATE_MAIN_MENU;
            print "[*] Login: $st->{username}\n";
            send_main_menu($fh, $st->{username}, get_user($st->{username}));
        } else {
            send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}INVALID PASSWORD.$NL") .
                          PETSCII_WHITE . ascii_to_petscii("${NL}USERNAME: "));
            $st->{state} = STATE_LOGIN_USER; $st->{username} = '';
        }

    # ── Register: username ────────────────────
    } elsif ($state eq STATE_REG_USER) {
        return send_ascii($fh, "${NL}CHOOSE A USERNAME: ") if $line eq '';
        if ($line !~ /^[a-zA-Z0-9_]{3,16}$/) {
            send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}3-16 CHARS, LETTERS/NUMBERS ONLY.$NL") .
                          PETSCII_WHITE . ascii_to_petscii("${NL}CHOOSE A USERNAME: ")); return;
        }
        if (user_exists($line)) {
            send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}USERNAME TAKEN.$NL") .
                          PETSCII_WHITE . ascii_to_petscii("${NL}CHOOSE A USERNAME: ")); return;
        }
        $st->{reg_user} = lc($line); $st->{state} = STATE_REG_PASS;
        send_ascii($fh, "${NL}CHOOSE A PASSWORD: ");

    # ── Register: password ────────────────────
    } elsif ($state eq STATE_REG_PASS) {
        if (length($line) < 4) {
            send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}MINIMUM 4 CHARACTERS.$NL") .
                          PETSCII_WHITE . ascii_to_petscii("${NL}CHOOSE A PASSWORD: ")); return;
        }
        $st->{reg_pass} = $line; $st->{state} = STATE_REG_CONFIRM;
        send_ascii($fh, "${NL}CONFIRM PASSWORD: ");

    # ── Register: confirm ─────────────────────
    } elsif ($state eq STATE_REG_CONFIRM) {
        if ($line ne $st->{reg_pass}) {
            send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}PASSWORDS DO NOT MATCH.$NL") .
                          PETSCII_WHITE . ascii_to_petscii("${NL}CHOOSE A PASSWORD: "));
            $st->{state} = STATE_REG_PASS; $st->{reg_pass} = ''; return;
        }
        create_user($st->{reg_user}, $st->{reg_pass});
        $st->{username} = $st->{reg_user};
        update_login($st->{username});
        $st->{state} = STATE_MAIN_MENU;
        print "[*] New user: $st->{username}\n";
        send_raw($fh, PETSCII_GREEN . ascii_to_petscii("${NL}ACCOUNT CREATED! WELCOME, " . uc($st->{username}) . "!$NL$NL"));
        send_main_menu($fh, $st->{username}, get_user($st->{username}));

    # ── Main menu ─────────────────────────────
    } elsif ($state eq STATE_MAIN_MENU) {
        my $ch = uc($line);
        if ($st->{pending_menu} && $ch eq '') {
            delete $st->{pending_menu};
            return send_main_menu($fh, $st->{username}, get_user($st->{username}));
        }
        if    ($ch eq '1') { _show_datetime($fh, $st); }
        elsif ($ch eq '2') { _show_who($fh, $st); }
        elsif ($ch eq '3') { _show_messages($fh, $st); }
        elsif ($ch eq '4') {
            $st->{state}   = STATE_MSG_WRITE;
            $st->{msg_buf} = '';
            _send_msg_write_screen($fh);
        }
        elsif ($ch eq '5') { $st->{state} = STATE_GAMES_MENU; send_games_menu($fh); }
        elsif ($ch eq 'Q') {
            send_raw($fh, PETSCII_YELLOW . ascii_to_petscii("${NL}GOODBYE, " . uc($st->{username}) . "!$NL"));
            _disconnect($fh, $select);
        } else {
            send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}INVALID CHOICE.$NL") .
                          PETSCII_WHITE . ascii_to_petscii("ENTER CHOICE: "));
        }

    # ── Write message ─────────────────────────
    } elsif ($state eq STATE_MSG_WRITE) {
        if (lc($line) eq '/done') {
            if (length($st->{msg_buf}) > 0) {
                save_message($st->{username}, $st->{msg_buf});
                send_raw($fh, PETSCII_GREEN . ascii_to_petscii("${NL}MESSAGE SAVED! THANK YOU.$NL"));
            } else {
                send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}NO MESSAGE ENTERED.$NL"));
            }
            $st->{state}        = STATE_MAIN_MENU;
            $st->{msg_buf}      = '';
            $st->{pending_menu} = 1;
            send_ascii($fh, "${NL}PRESS RETURN FOR MENU...");
        } else {
            $st->{msg_buf} .= "$line\n";
        }

    # ── Read messages ─────────────────────────
    } elsif ($state eq STATE_MSG_READ) {
        $st->{state} = STATE_MAIN_MENU;
        send_main_menu($fh, $st->{username}, get_user($st->{username}));

    # ── Games menu ────────────────────────────
    } elsif ($state eq STATE_GAMES_MENU) {
        my $ch = uc($line);
        if ($ch eq '1') {
            $st->{state} = STATE_DICE;
            send_dice_screen($fh, $st);
        } elsif ($ch eq 'B') {
            $st->{state} = STATE_MAIN_MENU;
            send_main_menu($fh, $st->{username}, get_user($st->{username}));
        } else {
            send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}INVALID CHOICE.$NL") .
                          PETSCII_WHITE . ascii_to_petscii("ENTER CHOICE: "));
        }

    # ── Dice ──────────────────────────────────
    } elsif ($state eq STATE_DICE) {
        _handle_dice($fh, $select, $st, $line);
    }
}

# ─────────────────────────────────────────────
# Dice High/Low Game
# ─────────────────────────────────────────────
sub _handle_dice {
    my ($fh, $select, $st, $line) = @_;
    my $ch = uc($line);

    if ($ch eq 'B') {
        $st->{state} = STATE_GAMES_MENU;
        return send_games_menu($fh);
    }

    my $score = $st->{dice_score} // 100;
    my ($bet, $choice) = (0, '');

    if    ($ch =~ /^(\d+)\s*([HLS])$/) { ($bet, $choice) = ($1, $2); }
    elsif ($ch =~ /^([HLS])$/)         { $bet = $st->{dice_bet} || 10; $choice = $1; }
    else {
        send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}ENTER: <AMOUNT><H/L/S>  E.G. 10H$NL") .
                      PETSCII_WHITE . ascii_to_petscii("YOUR BET: ")); return;
    }

    $bet = $score if $bet > $score;
    $bet = 1      if $bet < 1;
    $st->{dice_bet} = $bet;

    my $d1    = int(rand(6)) + 1;
    my $d2    = int(rand(6)) + 1;
    my $total = $d1 + $d2;
    my $cat   = $total <= 6 ? 'L' : $total == 7 ? 'S' : 'H';

    my ($won, $payout) = (0, 0);
    if ($choice eq $cat) {
        $payout = ($choice eq 'S') ? $bet * 4 : $bet;
        $st->{dice_score} += $payout;
        $st->{dice_wins}++;
        $won = 1;
    } else {
        $st->{dice_score} -= $bet;
        $st->{dice_losses}++;
    }

    my $cat_word    = $cat eq 'H' ? 'HIGH' : $cat eq 'L' ? 'LOW' : 'SEVEN';
    my $result_col  = $won ? PETSCII_GREEN : PETSCII_RED;
    my $result_text = $won
        ? "  YOU WIN " . ($choice eq 'S' ? "$payout (4:1 BONUS!)" : $payout) . "!"
        : "  YOU LOSE $bet!";

    send_raw($fh,
        PETSCII_CYAN   . ascii_to_petscii($NL . "-" x 38 . $NL) .
        PETSCII_WHITE  . ascii_to_petscii("  ROLLING THE DICE...$NL$NL") .
        PETSCII_YELLOW . ascii_to_petscii("  [D$d1] [D$d2]  =  TOTAL: $total ($cat_word)$NL$NL") .
        $result_col    . ascii_to_petscii("  $result_text$NL") .
        PETSCII_WHITE  . ascii_to_petscii("  SCORE: " . $st->{dice_score} . "$NL") .
        PETSCII_CYAN   . ascii_to_petscii("-" x 38 . $NL)
    );

    if ($st->{dice_score} <= 0) {
        send_raw($fh, PETSCII_RED . ascii_to_petscii("${NL}  YOU'RE BROKE! RESETTING TO 100.$NL") .
                      PETSCII_WHITE . ascii_to_petscii("  PRESS RETURN..."));
        $st->{dice_score}   = 100;
        $st->{pending_dice} = 1;
        return;
    }

    if ($st->{pending_dice}) {
        delete $st->{pending_dice};
        send_dice_screen($fh, $st);
        return;
    }

    send_raw($fh, PETSCII_GREEN . ascii_to_petscii("${NL}  PLAY AGAIN? BET+CHOICE OR [B] BACK$NL") .
                  PETSCII_WHITE . ascii_to_petscii("YOUR BET: "));
}

# ─────────────────────────────────────────────
# Helper Screen Senders
# ─────────────────────────────────────────────
sub _send_login_prompt {
    my ($fh) = @_;
    send_raw($fh,
        PETSCII_CLR . PETSCII_CYAN . divider() .
        PETSCII_YELLOW . ascii_to_petscii("  LOGIN$NL") .
        PETSCII_CYAN   . divider() .
        PETSCII_WHITE  . ascii_to_petscii("${NL}USERNAME: "));
}

sub _send_reg_prompt {
    my ($fh) = @_;
    send_raw($fh,
        PETSCII_CLR . PETSCII_CYAN . divider() .
        PETSCII_YELLOW . ascii_to_petscii("  NEW USER REGISTRATION$NL") .
        PETSCII_CYAN   . divider() .
        PETSCII_WHITE  . ascii_to_petscii("${NL}CHOOSE A USERNAME: "));
}

sub _send_msg_write_screen {
    my ($fh) = @_;
    send_raw($fh,
        PETSCII_CLR . PETSCII_CYAN . divider() .
        PETSCII_YELLOW . ascii_to_petscii("  LEAVE A MESSAGE$NL") .
        PETSCII_CYAN   . divider() .
        PETSCII_WHITE  . ascii_to_petscii("TYPE YOUR MESSAGE BELOW.$NL") .
                         ascii_to_petscii("TYPE /DONE WHEN FINISHED.$NL") .
        PETSCII_CYAN   . divider() .
        PETSCII_GREEN  . ascii_to_petscii("$NL"));
}

sub _show_messages {
    my ($fh, $st) = @_;
    my $msgs = load_messages();
    send_raw($fh,
        PETSCII_CLR .
        PETSCII_CYAN   . divider() .
        PETSCII_YELLOW . ascii_to_petscii("  MESSAGE BOARD$NL") .
        PETSCII_CYAN   . divider()
    );
    if (!@$msgs) {
        send_raw($fh, PETSCII_WHITE . ascii_to_petscii("  NO MESSAGES YET.$NL"));
    } else {
        for my $msg (@$msgs) {
            send_raw($fh,
                PETSCII_YELLOW . ascii_to_petscii("FROM: " . uc($msg->{from}) . "$NL") .
                PETSCII_CYAN   . ascii_to_petscii("DATE: $msg->{date}$NL") .
                PETSCII_WHITE  . ascii_to_petscii($msg->{text} . "$NL") .
                thin_div()
            );
        }
    }
    $st->{state} = STATE_MSG_READ;
    send_raw($fh, PETSCII_WHITE . ascii_to_petscii("${NL}PRESS RETURN FOR MENU..."));
}

sub _show_datetime {
    my ($fh, $st) = @_;
    my @t  = localtime;
    my $dt = sprintf("%04d-%02d-%02d %02d:%02d:%02d", $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]);
    send_raw($fh,
        PETSCII_CYAN   . ascii_to_petscii("${NL}SERVER DATE/TIME: ") .
        PETSCII_YELLOW . ascii_to_petscii("$dt$NL") .
        PETSCII_WHITE  . ascii_to_petscii("${NL}PRESS RETURN FOR MENU..."));
    $st->{pending_menu} = 1;
}

sub _show_who {
    my ($fh, $st) = @_;
    my $list = '';
    for my $c (values %clients) {
        next unless $c->{username};
        $list .= "  " . uc($c->{username}) . " FROM " . $c->{addr} . $NL;
    }
    $list ||= "  NOBODY ELSE IS ONLINE.$NL";
    send_raw($fh,
        PETSCII_CYAN   . divider() .
        PETSCII_YELLOW . ascii_to_petscii("  WHO IS ONLINE$NL") .
        PETSCII_CYAN   . divider() .
        PETSCII_WHITE  . ascii_to_petscii($list) .
                         ascii_to_petscii("${NL}PRESS RETURN FOR MENU..."));
    $st->{pending_menu} = 1;
}

# ─────────────────────────────────────────────
# Disconnect
# ─────────────────────────────────────────────
sub _disconnect {
    my ($fh, $select) = @_;
    my $addr = $clients{$fh}{addr} // 'unknown';
    print "[-] Disconnected: $addr\n";
    $select->remove($fh); delete $clients{$fh}; $fh->close();
}
