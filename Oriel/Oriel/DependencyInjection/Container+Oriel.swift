import FactoryKit

extension Container {
  var applicationInfoRepository: Factory<any ApplicationInfoRepository> {
    self { BundleApplicationInfoRepository() }
      .singleton
  }

  var folderAccessRepository: Factory<any FolderAccessRepository> {
    self { BookmarkFolderAccessRepository() }
      .singleton
  }

  var fileOperationRepository: Factory<any FileOperationRepository> {
    self { LocalFileOperationRepository() }
      .singleton
  }

  var mediaRepository: Factory<any MediaRepository> {
    self { LocalMediaRepository() }
      .singleton
  }

  @MainActor
  var recentsFolderRepository: Factory<any RecentsFolderRepository> {
    #if os(macOS)
      self { SystemRecentsFolderRepository(folderAccess: self.folderAccessRepository()) }
        .singleton
    #else
      self { LocalRecentsFolderRepository(folderAccess: self.folderAccessRepository()) }
        .singleton
    #endif
  }

  @MainActor
  var welcomeFeatureModel: Factory<any WelcomeFeatureModelProtocol> {
    self {
      WelcomeFeatureModel(
        applicationInfo: self.applicationInfoRepository(),
        folderAccess: self.folderAccessRepository(),
        recents: self.recentsFolderRepository()
      )
    }
  }

  @MainActor
  var mediaBrowserFeatureModel: ParameterFactory<Folder, any MediaBrowserFeatureModelProtocol> {
    self {
      MediaBrowserFeatureModel(
        folder: $0,
        mediaRepository: self.mediaRepository(),
        fileOperations: self.fileOperationRepository(),
        folderAccess: self.folderAccessRepository()
      )
    }
  }

  #if os(macOS)
    @MainActor
    var applicationWindowCoordinator: Factory<any ApplicationWindowCoordinatorProtocol> {
      self {
        ApplicationWindowCoordinator(
          folderAccess: self.folderAccessRepository(),
          recents: self.recentsFolderRepository()
        )
      }
      .singleton
    }

    @MainActor
    var folderWindowFeatureModel: ParameterFactory<Folder.ID, any FolderWindowFeatureModelProtocol>
    {
      self {
        FolderWindowFeatureModel(
          folderID: $0,
          folderAccess: self.folderAccessRepository()
        )
      }
    }
  #endif
}
