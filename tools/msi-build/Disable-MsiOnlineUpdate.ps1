# Adapt the pre-#27213 template for individually packaged, offline MSI releases.
function Disable-MsiOnlineUpdate {
    param([Parameter(Mandatory)][string] $ProductWxsPath)
    $document = New-Object Xml.XmlDocument
    $document.PreserveWhitespace = $true
    $document.Load($ProductWxsPath)
    $ns = New-Object Xml.XmlNamespaceManager($document.NameTable)
    $ns.AddNamespace('w', 'http://schemas.microsoft.com/wix/2006/wi')
    $selectors = @(
        '//w:Property[@Id="PREVIOUS_USE_MU" or @Id="PREVIOUS_ENABLE_MU"]',
        '//w:SetProperty[@Id="USE_MU" or @Id="ENABLE_MU" or @Id="EnableMU"]',
        '//w:CustomAction[@Id="EnableMU"]',
        '//w:Custom[@Action="EnableMU"]',
        '//w:Component[@Id="MURegistryEntries"]',
        '//w:ComponentRef[@Id="MURegistryEntries"]',
        '//w:RegistryValue[@Name="UseMU" or @Name="EnableMU"]',
        '//w:Fragment[w:UI/w:Dialog[@Id="MuDialog"]]',
        '//w:DialogRef[@Id="MuDialog"]',
        '//w:Publish[@Dialog="MuDialog"]'
    )
    foreach ($selector in $selectors) {
        foreach ($node in @($document.SelectNodes($selector, $ns))) { [void] $node.ParentNode.RemoveChild($node) }
    }
    foreach ($node in @($document.SelectNodes('//w:Publish[@Value="MuDialog"]', $ns))) {
        if ($node.GetAttribute('Dialog') -eq 'ExplorerContextMenuDialog' -and $node.GetAttribute('Control') -eq 'Next') {
            $node.SetAttribute('Value', 'VerifyReadyDlg')
        } elseif ($node.GetAttribute('Dialog') -eq 'VerifyReadyDlg' -and $node.GetAttribute('Control') -eq 'Back') {
            $node.SetAttribute('Value', 'ExplorerContextMenuDialog')
        } else { throw 'Unexpected navigation to the removed Microsoft Update dialog.' }
    }
    foreach ($node in @($document.SelectNodes('//comment()'))) {
        if ($node.Value -match 'Microsoft Update|\bMU\b|USE_MU|ENABLE_MU|MuDialog|EnableMU|UseMU') { [void] $node.ParentNode.RemoveChild($node) }
    }
    $document.Save($ProductWxsPath)
    if ((Get-Content -LiteralPath $ProductWxsPath -Raw) -match 'USE_MU|ENABLE_MU|RegisterMicrosoftUpdate|MuDialog|EnableMU|UseMU|Microsoft Update') {
        throw 'The template still contains an online/Microsoft Update integration reference.'
    }
}
