use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile tempdir);
use File::Spec;
use JSON::PP;

my $loaded=do './bin/cloudflare-api';
ok($loaded, 'CLI functions load');

is(typed_value('string', 'hello'), 'hello', 'string input');
ok(typed_value('bool', 'true'), 'boolean true');
ok(!typed_value('bool', 'false'), 'boolean false');
is_deeply(typed_value('array', '[1,2]'), [1,2], 'array input');
is_deeply(typed_value('hash', '{"a":1}'), {a => 1}, 'hash input');
is_deeply(typed_value('json', '{"a":[1]}'), {a => [1]}, 'JSON input');

my ($fh, $path)=tempfile();
print $fh '{"name":"from file"}';
close($fh);
is_deeply(typed_value('json-file', $path), {name => 'from file'}, 'JSON file input');

my ($dump_fh, $dump_path)=tempfile();
print $dump_fh "\$VAR1 = { 'name' => 'trusted' };\n";
close($dump_fh);
is_deeply(typed_value('dumper-file', $dump_path), {name => 'trusted'},
    'trusted Data::Dumper file input');

my ($key, $value)=parse_named('json', 'binding={"type":"plain_text"}');
is($key, 'binding', 'named parameter key');
is_deeply($value, {type => 'plain_text'}, 'named parameter JSON value');

my %seen;
is_deeply(next_query({per_page => 2}, {result_info => {page => 1,
    per_page => 2, total_count => 5}}, 1, \%seen),
    {per_page => 2, page => 2}, 'count-based pagination');
is_deeply(next_query({per_page => 2}, {result_info => {page => 1,
    total_pages => 3}}, 1, \%seen),
    {per_page => 2, page => 2}, 'page-based pagination');
is_deeply(next_query({}, {result_info => {cursor => 'abc'}}, 1, \%seen),
    {cursor => 'abc'}, 'cursor pagination');
is(next_query({}, {result_info => {page => 2, total_pages => 2}}, 2, \%seen),
    undef, 'pagination ends');

my $error=eval { typed_value('bool', 'maybe'); 1 };
ok(!$error && $@=~/boolean must be true or false/, 'invalid boolean rejected');
$error=eval { typed_value('array', '{}'); 1 };
ok(!$error && $@=~/requires a JSON array/, 'wrong JSON type rejected');
$error=eval { next_query({}, {result_info => {cursor => 'abc'}}, 2, \%seen); 1 };
ok(!$error && $@=~/cursor repeated/, 'repeated cursor rejected');

my $command="$^X -Ilib bin/cloudflare-api --resource kv --action list_namespaces --paginate --max-pages 2 --per-page 5 --dump-opt";
my $output=`$command 2>&1`;
is($? >> 8, 0, 'CLI options accepted');
like($output, qr/'max-pages' => 2/, 'page limit in parsed options');
like($output, qr/'per_page' => 5/, 'page size in parsed parameters');

$command="$^X -Ilib bin/cloudflare-api --resource kv --action list_namespaces --dump_opt";
$output=`$command 2>&1`;
is($? >> 8, 0, 'WebDyne-style dump_opt alias accepted');
like($output, qr/'dump_opt' => 1/, 'dump_opt uses the canonical option key');

my ($asset_json_fh, $asset_json_fn)=tempfile();
print($asset_json_fh '["from-json.html",{"path":"local/site.css","name":"css/site.css"}]');
close($asset_json_fh);
my ($asset_text_fh, $asset_text_fn)=tempfile();
print($asset_text_fh "text file.css\n\nsecond.txt\r\n");
close($asset_text_fh);
my ($asset_stdin_fh, $asset_stdin_fn)=tempfile();
print($asset_stdin_fh "from stdin.html\n\nlast.png\n");
close($asset_stdin_fh);

$command="$^X -Ilib bin/cloudflare-api --resource workers --action upload_assets --arg worker --asset first.html --asset-list-json $asset_json_fn --asset-list-text $asset_text_fn --asset final.js --asset-list-stdin --param prefix=/docs --dump-opt < $asset_stdin_fn";
$output=`$command 2>&1`;
is($? >> 8, 0, 'asset sources combine for Worker asset upload');
like($output, qr/'first\.html'.*'from-json\.html'.*'text file\.css'.*'second\.txt'.*'final\.js'.*'from stdin\.html'.*'last\.png'/s,
    'asset sources retain option and line order, including spaces in filenames');
like($output, qr/'name' => 'css\/site\.css'/, 'JSON asset entry retains URL name');
like($output, qr/'prefix' => '\/docs'/, 'asset prefix is passed as named option');

$command="$^X -Ilib bin/cloudflare-api --resource workers --action upload_assets --arg worker --arg dist --asset first.html --dump-opt";
$output=`$command 2>&1`;
isnt($? >> 8, 0, 'asset list cannot mix with directory source argument');
like($output, qr/require one Worker name and no other source argument/,
    'mixed source error explains the accepted form');

$command="$^X -Ilib bin/cloudflare-api --resource kv --action list_namespaces --asset first.html --dump-opt";
$output=`$command 2>&1`;
isnt($? >> 8, 0, 'asset options rejected for another action');
like($output, qr/require --resource workers --action upload_assets/,
    'asset options error identifies the Worker action');

$command="$^X -Ilib bin/cloudflare-api --resource workers --action upload_assets --arg worker --asset-list-stdin --asset-list-stdin --dump-opt";
$output=`$command 2>&1`;
isnt($? >> 8, 0, 'repeated stdin source rejected before reading stdin');
like($output, qr/--asset-list-stdin may be used only once/,
    'repeated stdin source error is clear');

$command="$^X -Ilib bin/cloudflare-api --resource workers --action upload_assets --arg worker --asset-list-text $asset_stdin_fn --dump-opt";
$output=`$command 2>&1`;
is($? >> 8, 0, 'line-based asset file accepted on its own');
like($output, qr/'from stdin\.html'.*'last\.png'/s,
    'line-based asset file ignores blank lines');

$command="$^X -Ilib bin/cloudflare-api --version";
$output=`$command 2>&1`;
is($? >> 8, 0, 'version option accepted');
is($output, "cloudflare-api $Cloudflare::API::VERSION\n", 'version output unchanged');

my $wrangler_dn=tempdir(CLEANUP => 1);
my $wrangler_fn=File::Spec->catfile($wrangler_dn, 'wrangler');
open(my $wrangler_fh, '>', $wrangler_fn) || die "unable to create mock Wrangler: $!";
print $wrangler_fh <<'MOCK';
#!/usr/bin/env perl
use strict;
use warnings;
exit(2) unless join(' ', @ARGV) eq 'auth token --json';
exit(1) if $ENV{'MOCK_WRANGLER_FAIL'};
print $ENV{'MOCK_WRANGLER_JSON'};
MOCK
close($wrangler_fh) || die "unable to close mock Wrangler: $!";
chmod(0755, $wrangler_fn) || die "unable to make mock Wrangler executable: $!";
{
    local $ENV{'PATH'}=$wrangler_dn.':'.$ENV{'PATH'};
    local $ENV{'MOCK_WRANGLER_JSON'}='{"type":"oauth","token":"oauth-test-token"}';
    is(wrangler_token(), 'oauth-test-token', 'Wrangler OAuth token accepted');
    $ENV{'MOCK_WRANGLER_JSON'}='{"type":"api_token","token":"api-test-token"}';
    is(wrangler_token(), 'api-test-token', 'Wrangler API token accepted');
    $ENV{'MOCK_WRANGLER_JSON'}='{"type":"api_key","key":"secret-key","email":"x@example.test"}';
    $error=eval { wrangler_token(); 1 };
    ok(!$error && $@=~/unsupported credential type/, 'API key credentials rejected');
    unlike($@, qr/secret-key/, 'API key is absent from error');
    $ENV{'MOCK_WRANGLER_JSON'}='secret-output';
    $error=eval { wrangler_token(); 1 };
    ok(!$error && $@=~/invalid JSON/, 'invalid Wrangler output rejected');
    unlike($@, qr/secret-output/, 'invalid output is absent from error');
    $ENV{'MOCK_WRANGLER_JSON'}='{"type":"oauth","token":"bad\\nheader"}';
    $error=eval { wrangler_token(); 1 };
    ok(!$error && $@=~/no usable token/, 'token containing a control character rejected');
    local $ENV{'MOCK_WRANGLER_FAIL'}=1;
    $error=eval { wrangler_token(); 1 };
    ok(!$error && $@=~/check Wrangler login/, 'Wrangler failure explains login');
}

$command="$^X -Ilib bin/cloudflare-api --auth=other --resource accounts --action list --dump-opt";
$output=`$command 2>&1`;
isnt($? >> 8, 0, 'unknown authentication source rejected');
like($output, qr/auth must be wrangler/, 'authentication source error is clear');

$command="$^X -Ilib bin/cloudflare-api --auth=wrangler --resource accounts --action list --dump-opt";
$output=`$command 2>&1`;
is($? >> 8, 0, 'Wrangler option accepted without fetching credentials in dump mode');

$command="$^X -Ilib bin/cloudflare-api --resource r2 --action delete_bucket --arg x --paginate --dump-opt";
$output=`$command 2>&1`;
isnt($? >> 8, 0, 'pagination rejected for non-list action');
like($output, qr/--paginate requires a list action/, 'pagination error is clear');

$command="$^X -Ilib bin/cloudflare-api --resource secrets_store --action create_secret --arg store --arg-json '[{\"name\":\"x\",\"value\":\"secret\",\"scopes\":[\"workers\"]}]' --dump-opt";
$output=`$command 2>&1`;
isnt($? >> 8, 0, 'secret-bearing action cannot dump parsed options');
unlike($output, qr/secret\"/, 'secret value not dumped');

done_testing();
